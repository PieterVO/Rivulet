//
//  TriviaFactTests.swift
//  RivuletTests
//
//  Decode + spoiler/suppression filtering for the Insights trivia store.
//

import XCTest
@testable import Rivulet

final class TriviaFactTests: XCTestCase {

    private let payload = """
    {
      "id": "tmdb://27205",
      "type": "movie",
      "generatedAt": "2026-07-07T00:00:00Z",
      "pipelineVersion": 1,
      "attribution": [ { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } ],
      "facts": [
        { "id": "f_prod1", "text": "Nolan wrote the first draft over nine years.",
          "category": "production", "spoiler": 0,
          "source": { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } },
        { "id": "f_plot1", "text": "The ending leaves the top spinning ambiguously.",
          "category": "reference", "spoiler": 1,
          "source": { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } },
        { "id": "f_cast1", "text": "Tom Hardy improvised several lines.",
          "category": "casting", "spoiler": 0,
          "source": { "name": "Inception Wiki", "url": "https://inception.fandom.com" } },
        { "id": "f_unknown", "text": "A fact in a future category.",
          "category": "brand_new_category", "spoiler": 0,
          "source": { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } }
      ]
    }
    """.data(using: .utf8)!

    private func decoded() throws -> TitleTrivia {
        try JSONDecoder().decode(TitleTrivia.self, from: payload)
    }

    func testDecodesPayloadAndUnknownCategoryDegradesToOther() throws {
        let trivia = try decoded()
        XCTAssertEqual(trivia.id, "tmdb://27205")
        XCTAssertEqual(trivia.facts.count, 4)
        XCTAssertEqual(trivia.attribution.first?.name, "Wikipedia")
        // Unknown server category must not fail the payload — degrades to .other.
        XCTAssertEqual(trivia.facts.last?.category, .other)
    }

    func testMissingSpoilerFieldFailsClosedAndIsHidden() throws {
        // A fact with no spoiler field must default to a spoiler (fail closed),
        // so a corrupt payload hides it under hide-spoilers rather than leaking.
        let noSpoiler = """
        { "id": "tmdb://1", "type": "movie", "generatedAt": "", "pipelineVersion": 1,
          "attribution": [],
          "facts": [ { "id": "f_nospoil", "text": "A fact with no spoiler field.",
            "category": "production",
            "source": { "name": "Wikipedia", "url": "https://w/x" } } ] }
        """.data(using: .utf8)!
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: noSpoiler)
        XCTAssertGreaterThanOrEqual(trivia.facts[0].spoiler, 1, "missing spoiler must fail closed (>= 1)")
        let visible = trivia.visibleFacts(hideSpoilers: true, suppressed: [])
        XCTAssertTrue(visible.isEmpty, "a fail-closed fact must be hidden when spoilers are hidden")
    }

    func testHideSpoilersDropsLevelOneAndAbove() throws {
        let trivia = try decoded()
        let visible = trivia.visibleFacts(hideSpoilers: true, suppressed: [])
        XCTAssertFalse(visible.contains { $0.id == "f_plot1" }, "level-1 spoiler must be hidden")
        XCTAssertTrue(visible.contains { $0.id == "f_prod1" })
    }

    func testShowSpoilersKeepsAll() throws {
        let trivia = try decoded()
        let visible = trivia.visibleFacts(hideSpoilers: false, suppressed: [])
        XCTAssertEqual(visible.count, 4)
    }

    func testSuppressedFactsAlwaysDropped() throws {
        let trivia = try decoded()
        let visible = trivia.visibleFacts(hideSpoilers: false, suppressed: ["f_cast1"])
        XCTAssertFalse(visible.contains { $0.id == "f_cast1" }, "suppressed fact must be hidden even with spoilers shown")
        XCTAssertEqual(visible.count, 3)
    }

    func testVisibleFactsOrderedByCategory() throws {
        let trivia = try decoded()
        let visible = trivia.visibleFacts(hideSpoilers: false, suppressed: [])
        // production (0) before casting (1) before reference (3) before other (7).
        let cats = visible.map { $0.category }
        XCTAssertEqual(cats, [.production, .casting, .reference, .other])
    }
}
