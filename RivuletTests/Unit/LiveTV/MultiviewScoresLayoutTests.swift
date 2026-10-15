// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MultiviewScoresLayoutTests.swift
//  RivuletTests
//
//  When multiview offers its scores layout, when it drops back to the grid,
//  and where the tile and list go.
//

import XCTest
@testable import Rivulet

@MainActor
final class MultiviewScoresLayoutTests: XCTestCase {
    private typealias VM = MultiStreamViewModel
    private let kickoff = Date(timeIntervalSince1970: 1_800_000_000)

    private func team(_ abbr: String, _ location: String, _ nickname: String) -> ScoreTeam {
        ScoreTeam(abbr: abbr, name: "\(location) \(nickname)", short: nickname, nickname: nickname,
                  location: location, score: nil, logo: nil)
    }

    private var boards: [League: Scoreboard] {
        let game = ScoreGame(id: "g", state: .in, start: kickoff, detail: "Q1", network: nil,
                             away: team("CHI", "Chicago", "Bears"), home: team("ATL", "Atlanta", "Falcons"))
        return [.nfl: Scoreboard(league: .nfl, fetchedAt: kickoff, stale: false, poll: 30, games: [game])]
    }

    private func channel(_ id: String) -> UnifiedChannel {
        UnifiedChannel(id: id, sourceType: .genericM3U, sourceId: "s", name: id)
    }

    private func program(_ title: String) -> UnifiedProgram {
        UnifiedProgram(id: title, channelId: "c", title: title, startTime: kickoff,
                       endTime: kickoff.addingTimeInterval(3.5 * 3600))
    }

    func test_offeredForOneStreamShowingAGame() {
        let match = VM.scoresMatch(channels: [channel("a")], boards: boards,
                                   program: { _ in self.program("Live: Chicago Bears @ Atlanta Falcons") })
        XCTAssertEqual(match?.game.id, "g")
        XCTAssertEqual(match?.league, .nfl)
    }

    func test_notOfferedWithoutAGameOrWithTwoStreams() {
        let game = { (_: UnifiedChannel) in self.program("Bears at Falcons") }
        XCTAssertNil(VM.scoresMatch(channels: [channel("a"), channel("b")], boards: boards, program: game))
        XCTAssertNil(VM.scoresMatch(channels: [], boards: boards, program: game))
        XCTAssertNil(VM.scoresMatch(channels: [channel("a")], boards: boards, program: { _ in self.program("Seinfeld") }))
        XCTAssertNil(VM.scoresMatch(channels: [channel("a")], boards: boards, program: { _ in nil }))
        XCTAssertNil(VM.scoresMatch(channels: [channel("a")], boards: [:], program: game))
    }

    func test_secondStreamDropsScoresToGrid() {
        let id = UUID()
        XCTAssertEqual(VM.settled(.scores(mainId: id), streamCount: 1), .scores(mainId: id))
        XCTAssertEqual(VM.settled(.scores(mainId: id), streamCount: 2), .grid)
        XCTAssertEqual(VM.settled(.scores(mainId: id), streamCount: 0), .grid)
        XCTAssertEqual(VM.settled(.focus(mainId: id), streamCount: 2), .focus(mainId: id))
    }

    func test_scoresPlan_wideRect() {
        // Watch mode on 1920x1080: the tile is width-bound, centred vertically.
        let rect = CGRect(x: 48, y: 84, width: 1824, height: 912)
        let plan = LiveMultiviewViewController.scoresPlan(in: rect, gap: 36)
        XCTAssertEqual(plan.main.minX, 48)
        XCTAssertEqual(plan.main.width, 1192, accuracy: 0.01)
        XCTAssertEqual(plan.main.width / plan.main.height, 16 / 9, accuracy: 0.001)
        XCTAssertEqual(plan.main.midY, rect.midY, accuracy: 0.01)
        XCTAssertEqual(plan.list.minX, plan.main.maxX + 36, accuracy: 0.01)
        XCTAssertEqual(plan.list.maxX, rect.maxX, accuracy: 0.01)
        XCTAssertEqual(plan.list.minY, rect.minY)
        XCTAssertEqual(plan.list.height, rect.height)
    }

    func test_scoresPlan_shortRect() {
        // Edit mode's short tile area: the tile is height-bound and the list takes the rest.
        let rect = CGRect(x: 90, y: 110, width: 1740, height: 450)
        let plan = LiveMultiviewViewController.scoresPlan(in: rect, gap: 36)
        XCTAssertEqual(plan.main.height, 450, accuracy: 0.01)
        XCTAssertEqual(plan.main.width, 800, accuracy: 0.01)
        XCTAssertEqual(plan.list.width, 1740 - 800 - 36, accuracy: 0.01)
    }
}
