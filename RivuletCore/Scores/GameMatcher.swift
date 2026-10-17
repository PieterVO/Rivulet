// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  GameMatcher.swift
//  Rivulet
//
//  Which scoreboard game a guide programme is showing, and which channel is
//  airing a game. A programme matches when its title (or, failing that, the
//  description's first sentence) names both teams and the game starts within
//  four hours of the programme's slot.
//

import Foundation

enum GameMatcher {
    /// How far a game's start may sit outside the programme's slot.
    static let slack: TimeInterval = 4 * 3600

    /// Whether a programme might be a game: worth fetching scores for.
    static func mightBeGame(_ program: UnifiedProgram) -> Bool {
        if program.isPregameBlock || program.isLiveAiring { return true }
        if program.category?.localizedCaseInsensitiveContains("sport") == true { return true }
        return program.title.contains(/(?i)\s(@|vs\.?|v\.?|at)\s/)
    }

    /// The game `program` is showing, preferring the league its guide names.
    static func game(for program: UnifiedProgram, channel: UnifiedChannel?,
                     in boards: [League: Scoreboard]) -> (league: League, game: ScoreGame)? {
        let hint = leagueHint(program, channel: channel)
        let guide = GuideText(program)
        let found = League.allCases.flatMap { league in
            (boards[league]?.games ?? []).filter { guide.matches($0) }.map { (league: league, game: $0) }
        }
        return found.min { a, b in
            if (a.league == hint) != (b.league == hint) { return a.league == hint }
            return abs(a.game.start.timeIntervalSince(program.eventStart))
                < abs(b.game.start.timeIntervalSince(program.eventStart))
        }
    }

    /// The channel airing `game` now, preferring a live airing over a replay.
    static func channel(airing game: ScoreGame, channels: [UnifiedChannel],
                        current: (UnifiedChannel) -> UnifiedProgram?) -> UnifiedChannel? {
        self.channels(airing: [game], channels: channels, current: current)[game.id]
    }

    /// The channel airing each game, by game id. Reads each channel's guide once,
    /// so a whole board costs one pass over the lineup, not one per game.
    static func channels(airing games: [ScoreGame], channels: [UnifiedChannel],
                         current: (UnifiedChannel) -> UnifiedProgram?) -> [String: UnifiedChannel] {
        let guides = channels.compactMap { channel in
            current(channel).flatMap { mightBeGame($0) ? (channel, $0.isLiveAiring, GuideText($0)) : nil }
        }
        var result: [String: UnifiedChannel] = [:]
        for game in games {
            let airing = guides.filter { $0.2.matches(game) }
            if let pick = airing.first(where: { $0.1 }) ?? airing.first { result[game.id] = pick.0 }
        }
        return result
    }

    static func matches(_ program: UnifiedProgram, _ game: ScoreGame) -> Bool {
        GuideText(program).matches(game)
    }

    /// A programme's searchable lines (title, then the description's lead), built once.
    private struct GuideText {
        let start: Date
        let end: Date
        let lines: [(text: String, words: Set<String>)]

        init(_ program: UnifiedProgram) {
            start = program.startTime
            end = program.endTime
            lines = ([program.displayTitle] + (program.description.map { [leadSentence($0)] } ?? [])).map {
                (normalized($0), Set($0.split { !$0.isLetter && !$0.isNumber }.map(String.init)))
            }
        }

        func matches(_ game: ScoreGame) -> Bool {
            guard game.start >= start.addingTimeInterval(-slack),
                  game.start <= end.addingTimeInterval(slack) else { return false }
            return lines.contains { names(game.away, in: $0.text, words: $0.words)
                && names(game.home, in: $0.text, words: $0.words) }
        }
    }

    /// Gracenote guides title every game "Live: College Football" and name the
    /// matchup only in the description's opening sentence; later sentences recap
    /// other teams, so only the first counts.
    static func leadSentence(_ description: String) -> String {
        let text = description.replacing(/\b(No|St|Jr|Mt)\.\s/) { "\($0.1) " }
        return text.split(separator: /[.!?]\s/, maxSplits: 1).first.map(String.init) ?? text
    }

    private static func names(_ team: ScoreTeam, in text: String, words: Set<String>) -> Bool {
        if team.abbr.count >= 2, words.contains(team.abbr) { return true }
        return [team.name, team.short, team.nickname, "\(team.location) \(team.nickname)"]
            .map(normalized)
            .contains { $0.count > 2 && text.contains($0) }
    }

    /// Lowercased, punctuation to spaces, padded so `contains(" bears ")` is a word match.
    private static func normalized(_ s: String) -> String {
        let words = s.lowercased().split { !$0.isLetter && !$0.isNumber }
        return " " + words.joined(separator: " ") + " "
    }

    private static func leagueHint(_ program: UnifiedProgram, channel: UnifiedChannel?) -> League? {
        let text = normalized([program.category, program.title, channel?.groupTitle, channel?.name]
            .compactMap { $0 }.joined(separator: " "))
        return League.allCases.first { league in
            league.guideWords.contains { text.contains(" \($0) ") }
        }
    }
}
