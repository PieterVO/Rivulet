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
        let found = League.allCases.flatMap { league in
            (boards[league]?.games ?? []).filter { matches(program, $0) }.map { (league: league, game: $0) }
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
        let airing = channels.compactMap { channel in
            current(channel).flatMap { matches($0, game) ? (channel, $0) : nil }
        }
        return (airing.first { $0.1.isLiveAiring } ?? airing.first)?.0
    }

    static func matches(_ program: UnifiedProgram, _ game: ScoreGame) -> Bool {
        guard game.start >= program.startTime.addingTimeInterval(-slack),
              game.start <= program.endTime.addingTimeInterval(slack) else { return false }
        return namesBoth(game, in: program.displayTitle)
            || program.description.map { namesBoth(game, in: leadSentence($0)) } == true
    }

    /// Gracenote guides title every game "Live: College Football" and name the
    /// matchup only in the description's opening sentence; later sentences recap
    /// other teams, so only the first counts.
    static func leadSentence(_ description: String) -> String {
        let text = description.replacing(/\b(No|St|Jr|Mt)\.\s/) { "\($0.1) " }
        return text.split(separator: /[.!?]\s/, maxSplits: 1).first.map(String.init) ?? text
    }

    private static func namesBoth(_ game: ScoreGame, in s: String) -> Bool {
        let text = normalized(s)
        let words = Set(s.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return names(game.away, in: text, words: words) && names(game.home, in: text, words: words)
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
