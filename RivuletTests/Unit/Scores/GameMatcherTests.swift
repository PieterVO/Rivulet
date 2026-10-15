// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  GameMatcherTests.swift
//  RivuletTests
//
//  Guide titles as Sports Editor, Plex and generic XMLTV write them, against
//  scoreboard games.
//

import XCTest
@testable import Rivulet

final class GameMatcherTests: XCTestCase {

    private let kickoff = Date(timeIntervalSince1970: 1_800_000_000)

    private func team(_ abbr: String, _ location: String, _ nickname: String, short: String? = nil) -> ScoreTeam {
        ScoreTeam(abbr: abbr, name: "\(location) \(nickname)", short: short ?? nickname, nickname: nickname,
                  location: location, score: nil, logo: nil)
    }

    private func game(_ away: ScoreTeam, _ home: ScoreTeam, start: Date? = nil, id: String = "g") -> ScoreGame {
        ScoreGame(id: id, state: .in, start: start ?? kickoff, detail: "Q1", network: nil, away: away, home: home)
    }

    private func program(_ title: String, from: TimeInterval = 0, to: TimeInterval = 3.5 * 3600,
                         category: String? = nil) -> UnifiedProgram {
        UnifiedProgram(id: title, channelId: "c", title: title, startTime: kickoff.addingTimeInterval(from),
                       endTime: kickoff.addingTimeInterval(to), category: category)
    }

    private func board(_ league: League, _ games: [ScoreGame]) -> Scoreboard {
        Scoreboard(league: league, fetchedAt: kickoff, stale: false, poll: 30, games: games)
    }

    private lazy var bears = team("CHI", "Chicago", "Bears")
    private lazy var falcons = team("ATL", "Atlanta", "Falcons")
    private lazy var bearsFalcons = game(bears, falcons)

    func test_titleStyles() {
        for title in ["Live: Chicago Bears @ Atlanta Falcons", "NFL Football: Bears at Falcons",
                      "Bears vs. Falcons", "NFL 12 - 1:00pm Bears at Falcons", "CHI @ ATL",
                      "UPCOMING: Chicago Bears @ Atlanta Falcons"] {
            XCTAssertTrue(GameMatcher.matches(program(title), bearsFalcons), title)
        }
    }

    func test_nearMisses() {
        for title in ["Chicago Bears Postgame Show", "Falcons Weekly", "No game scheduled",
                      "Chicago Med", "Bears at Packers"] {
            XCTAssertFalse(GameMatcher.matches(program(title), bearsFalcons), title)
        }
        // Abbreviations count only as uppercase words.
        XCTAssertFalse(GameMatcher.matches(program("chi and atl"), bearsFalcons))
    }

    func test_lastWeeksGameDoesNotMatch() {
        let lastWeek = game(bears, falcons, start: kickoff.addingTimeInterval(-7 * 86400))
        XCTAssertFalse(GameMatcher.matches(program("Bears at Falcons"), lastWeek))
        // A 24 h pregame block still matches the game at its end.
        let pregame = program("UPCOMING: Bears @ Falcons", from: -24 * 3600, to: 0)
        XCTAssertTrue(GameMatcher.matches(pregame, bearsFalcons))
    }

    func test_sameNicknameAcrossTeams() {
        let jets = team("NYJ", "New York", "Jets")
        let giants = team("NYG", "New York", "Giants")
        let patriots = team("NE", "New England", "Patriots")
        let games = [game(jets, patriots, id: "jets"), game(giants, team("DAL", "Dallas", "Cowboys"), id: "giants")]
        let match = GameMatcher.game(for: program("Live: New York Jets @ New England Patriots"), channel: nil,
                                     in: [.nfl: board(.nfl, games)])
        XCTAssertEqual(match?.game.id, "jets")
    }

    func test_leagueHintBreaksTie() {
        // Two Eagles teams, two Bears-like pairings: the guide's league word decides.
        let eagles = team("PHI", "Philadelphia", "Eagles")
        let collegeEagles = team("GASO", "Georgia Southern", "Eagles", short: "GA Southern")
        let bearcats = team("CHI", "Chicago", "Bears")
        let collegeBears = team("BAY", "Baylor", "Bears")
        let boards: [League: Scoreboard] = [
            .nfl: board(.nfl, [game(eagles, bearcats, id: "nfl")]),
            .collegeFootball: board(.collegeFootball, [game(collegeEagles, collegeBears, id: "cfb")]),
        ]
        let title = "Eagles at Bears"
        XCTAssertEqual(GameMatcher.game(for: program(title, category: "College Football"), channel: nil,
                                        in: boards)?.league, .collegeFootball)
        XCTAssertEqual(GameMatcher.game(for: program(title, category: "NFL"), channel: nil,
                                        in: boards)?.league, .nfl)
        let nflGroup = UnifiedChannel(id: "c", sourceType: .genericM3U, sourceId: "s", name: "NFL 12",
                                      groupTitle: "NFL Games")
        XCTAssertEqual(GameMatcher.game(for: program(title), channel: nflGroup, in: boards)?.league, .nfl)
    }

    func test_channelAiringGame() {
        let replay = UnifiedChannel(id: "replay", sourceType: .genericM3U, sourceId: "s", name: "NFL Replay")
        let live = UnifiedChannel(id: "live", sourceType: .genericM3U, sourceId: "s", name: "NFL 12")
        let other = UnifiedChannel(id: "news", sourceType: .genericM3U, sourceId: "s", name: "CNN")
        let current: [String: UnifiedProgram] = [
            "replay": program("Bears at Falcons"),
            "live": program("Live: Chicago Bears @ Atlanta Falcons"),
            "news": program("CNN News Central"),
        ]
        let channel = GameMatcher.channel(airing: bearsFalcons, channels: [replay, live, other]) { current[$0.id] }
        XCTAssertEqual(channel?.id, "live")
        XCTAssertNil(GameMatcher.channel(airing: game(team("DAL", "Dallas", "Cowboys"), falcons),
                                         channels: [replay, live, other]) { current[$0.id] })
    }

    func test_mightBeGame() {
        XCTAssertTrue(GameMatcher.mightBeGame(program("Bears at Falcons")))
        XCTAssertTrue(GameMatcher.mightBeGame(program("Live: SportsCenter")))
        XCTAssertTrue(GameMatcher.mightBeGame(program("Monday Night", category: "Sports event")))
        XCTAssertFalse(GameMatcher.mightBeGame(program("CNN News Central")))
    }

    func test_decodesWorkerBody() throws {
        let json = """
        {"league":"nfl","fetchedAt":"2026-10-15T18:01:02.345Z","stale":false,"poll":30,"games":[
          {"id":"401872995","state":"pre","start":"2026-10-16T00:15:00.000Z","detail":"10/15 - 8:15 PM EDT",
           "network":"Prime Video",
           "away":{"abbr":"SEA","name":"Seattle Seahawks","short":"Seahawks","nickname":"Seahawks",
                   "location":"Seattle","score":null,"logo":"https://a.espncdn.com/sea.png"},
           "home":{"abbr":"DEN","name":"Denver Broncos","short":"Broncos","nickname":"Broncos",
                   "location":"Denver","score":null,"logo":null}}]}
        """
        let board = try Scoreboard.decode(Data(json.utf8))
        XCTAssertEqual(board.league, .nfl)
        XCTAssertEqual(board.games.first?.state, .pre)
        XCTAssertEqual(board.games.first?.start, ISO8601DateFormatter().date(from: "2026-10-16T00:15:00Z"))
    }
}
