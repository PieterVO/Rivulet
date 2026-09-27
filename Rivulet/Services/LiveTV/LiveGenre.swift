// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveGenre.swift
//  Rivulet
//
//  The broad kind of thing on a channel, for What's On's genre rows and the
//  order of multiview's Add More row. Worked out on the device from the
//  guide's own categories, then the channel's name; nothing leaves the box.
//
//  Guides disagree on labels ("News & Documentary", "Bus./financial", bare
//  provider codes like "178"), so a label counts by the words in it, not by
//  an exact match.
//

import Foundation

enum LiveGenre: String, CaseIterable {
    case sports = "Sports"
    case news = "News"
    case kids = "Kids"
    case movies = "Movies"
    case documentaries = "Documentaries"
    case music = "Music"
    case entertainment = "Entertainment"

    /// Checked in `allCases` order, so "News & Documentary" is news and
    /// "Sports talk" is sports. A word matches a keyword it starts with.
    /// Matching anywhere inside a word misfiled common words ("transport" as
    /// sport, "signature" as nature), so only `suffixKeywords` also match at a
    /// word's end, for names run together ("AccuWeather", "Africanews").
    private var keywords: [String] {
        switch self {
        case .sports:
            return ["sport", "football", "soccer", "basketball", "baseball", "hockey", "golf", "tennis",
                    "racing", "motorsport", "boxing", "wrestling", "olympic", "espn", "nfl", "nba", "mlb",
                    "nhl", "ufc", "nascar", "cricket", "rugby"]
        case .news:
            return ["news", "weather", "affairs", "politic", "business", "financ"]
        case .kids:
            return ["kid", "child", "animat", "cartoon"]
        case .movies:
            return ["movie", "film", "cinema"]
        case .documentaries:
            return ["documentar", "history", "science", "nature", "travel", "factual", "explore"]
        case .music:
            return ["music", "concert"]
        case .entertainment:
            // Not "series": it is a format, and news channels carry it too.
            return ["entertainment", "comedy", "drama", "reality", "talk", "sitcom"]
        }
    }

    private static let suffixKeywords: Set<String> = ["news", "weather"]

    /// What `text` (a guide category, or a channel's name) says, if anything.
    /// Remembered per string: a guide repeats a few hundred labels across
    /// thousands of programmes, and What's On asks about all of them.
    static func from(_ text: String?) -> LiveGenre? {
        guard let text else { return nil }
        if let known = memo[text] { return known.genre }
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let genre = allCases.first { genre in
            genre.keywords.contains { keyword in
                words.contains { $0.hasPrefix(keyword) || (suffixKeywords.contains(keyword) && $0.hasSuffix(keyword)) }
            }
        }
        // ponytail: never evicted; bounded by the distinct labels and channel names seen.
        memo[text] = Memo(genre: genre)
        return genre
    }

    private struct Memo { let genre: LiveGenre? }
    private static var memo: [String: Memo] = [:]

    /// A channel's genre: what is on (`airing`, when given), else what it
    /// usually airs, else its name. Pass nil for a genre that holds still
    /// across programme boundaries.
    static func of(_ channel: UnifiedChannel, airing program: UnifiedProgram?,
                   guide: [UnifiedProgram]) -> LiveGenre? {
        if let genre = from(program?.category) { return genre }
        var counts: [LiveGenre: Int] = [:]
        for genre in guide.compactMap({ from($0.category) }) { counts[genre, default: 0] += 1 }
        if let best = counts.values.max() {
            return allCases.first { counts[$0] == best }
        }
        return from(channel.name)
    }

    /// A programme's own labels, less the ones that only name a genre or a
    /// format: two football games share "football", not "sports event".
    static func specificLabels(of program: UnifiedProgram?) -> Set<String> {
        guard let category = program?.category else { return [] }
        let generic: Set<String> = Set(allCases.map { $0.rawValue.lowercased() })
            .union(["sport", "sports event", "sports non-event", "series", "special", "news", "movie"])
        return Set(category.split(separator: ",").compactMap { part in
            let label = part.trimmingCharacters(in: .whitespaces).lowercased()
            guard !label.isEmpty, !generic.contains(label), label.contains(where: \.isLetter) else { return nil }
            return label
        })
    }
}
