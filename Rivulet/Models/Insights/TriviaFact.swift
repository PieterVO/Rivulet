//
//  TriviaFact.swift
//  Rivulet
//
//  Client models for the Insights trivia store (P2a). These decode the
//  static JSON published per title/episode by the offline trivia pipeline
//  and served by the insights-api Worker. Schema mirrors
//  Docs/superpowers/specs/2026-07-07-insights-trivia-pipeline-design.md.
//

import Foundation

/// One trivia fact about a title or episode.
nonisolated struct TriviaFact: Codable, Identifiable, Sendable, Hashable {
    /// Stable id (pipeline: hash of text+source.url). The report/suppress key.
    let id: String
    let text: String
    let category: TriviaCategory
    /// 0 = no spoiler · 1 = this title's plot · 2 = later episodes/seasons.
    let spoiler: Int
    let source: TriviaSource
    /// How interesting the fact is, 1-10, scored by the pipeline's extraction
    /// LLM. `nil` when absent (facts published before the field existed) — a
    /// distinct from a real low score, never eligible for Top 10 tab.
    let interest: Int?

    enum CodingKeys: String, CodingKey {
        case id, text, category, spoiler, source, interest
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        // Unknown categories degrade to `.other` rather than failing the whole
        // payload — the store's category enum may grow ahead of the client.
        category = (try? c.decode(TriviaCategory.self, forKey: .category)) ?? .other
        // Fail CLOSED on a missing/malformed spoiler tag: default to the
        // highest level (2) so a corrupt payload hides the fact under the
        // hide-spoilers toggle rather than leaking it over the user's video.
        // The pipeline always emits a valid 0/1/2; this guards R2 corruption
        // or a future schema change, where showing-by-default is the wrong risk.
        spoiler = (try? c.decode(Int.self, forKey: .spoiler)) ?? 2
        source = try c.decode(TriviaSource.self, forKey: .source)
        interest = try? c.decode(Int.self, forKey: .interest)
    }
}

/// Fact category. Ordering here is the display order of the grouped list.
nonisolated enum TriviaCategory: String, Codable, Sendable, CaseIterable {
    case production
    case casting
    case adaptation
    case reference
    case lore
    case goof
    case music
    case other   // client-only fallback for unknown server categories
}

nonisolated struct TriviaSource: Codable, Sendable, Hashable {
    let name: String
    let url: String
}

/// The full trivia payload for one title/episode.
nonisolated struct TitleTrivia: Codable, Sendable {
    let id: String            // e.g. "tmdb://27205"
    let type: String          // movie | episode | show
    let generatedAt: String
    let pipelineVersion: Int
    let attribution: [TriviaSource]
    let facts: [TriviaFact]
    let covered: Bool
    let releaseDate: String?

    enum CodingKeys: String, CodingKey {
        case id, type, generatedAt, pipelineVersion, attribution, facts, covered, releaseDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        generatedAt = (try? c.decode(String.self, forKey: .generatedAt)) ?? ""
        pipelineVersion = (try? c.decode(Int.self, forKey: .pipelineVersion)) ?? 0
        attribution = (try? c.decode([TriviaSource].self, forKey: .attribution)) ?? []
        facts = (try? c.decode([TriviaFact].self, forKey: .facts)) ?? []
        // Absent `covered` ⇒ true (backward-compat with objects published before
        // the tombstone field existed). A present `false` is a definitive
        // "generated, nothing to share" — the trigger must not re-request it.
        covered = (try? c.decode(Bool.self, forKey: .covered)) ?? true
        releaseDate = try? c.decode(String.self, forKey: .releaseDate)
    }
}

extension TitleTrivia {
    /// A present-but-empty object: the pipeline ran and found nothing. The panel
    /// shows no trivia section and the client stops re-requesting.
    var isTombstone: Bool { !covered }
}

extension TitleTrivia {
    /// Facts to display, honoring the user's hide-spoilers preference and the
    /// server-served suppression list, ordered by category (display order).
    ///
    /// - `hideSpoilers`: when true, drop any fact with `spoiler >= 1`. Without
    ///   playhead sync we can't know what the viewer has passed, so this-title
    ///   plot facts (level 1) are treated as spoilers too.
    /// - `suppressed`: fact ids the Worker reports as auto-hidden (report
    ///   threshold crossed). Always dropped regardless of the toggle.
    func visibleFacts(hideSpoilers: Bool, suppressed: Set<String>) -> [TriviaFact] {
        facts
            .filter { !suppressed.contains($0.id) }
            .filter { hideSpoilers ? $0.spoiler == 0 : true }
            .sorted { lhs, rhs in
                let li = TriviaCategory.allCases.firstIndex(of: lhs.category) ?? Int.max
                let ri = TriviaCategory.allCases.firstIndex(of: rhs.category) ?? Int.max
                return li < ri
            }
    }

    /// Curated "Top 10" tab: facts scoring >= 7 interest, sorted highest
    /// first, capped at 10. A `nil` interest (old-schema fact, not yet
    /// regenerated under the scoring pipeline) is never eligible.
    ///
    /// - `hideSpoilers`: when true, drop any fact with `spoiler >= 1`.
    /// - `suppressed`: fact ids to exclude (auto-hidden by Worker).
    func topTenFacts(hideSpoilers: Bool, suppressed: Set<String>) -> [TriviaFact] {
        facts
            .filter { !suppressed.contains($0.id) }
            .filter { hideSpoilers ? $0.spoiler == 0 : true }
            .filter { $0.interest != nil && $0.interest! >= 7 }
            .sorted { lhs, rhs in
                (lhs.interest ?? 0) > (rhs.interest ?? 0)
            }
            .prefix(10)
            .map { $0 }
    }
}
