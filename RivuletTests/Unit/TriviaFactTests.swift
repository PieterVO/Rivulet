// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TriviaFactTests.swift
//  RivuletTests
//
//  Decode + suppression filtering for the Insights trivia store.
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

    func testPlotFactsAreShown() throws {
        // Opening Trivia is asking for information, so a fact the pipeline tagged
        // as a plot spoiler (f_plot1) is shown like any other.
        let trivia = try decoded()
        let visible = trivia.visibleFacts(suppressed: [])
        XCTAssertEqual(visible.count, 4)
        XCTAssertTrue(visible.contains { $0.id == "f_plot1" })
    }

    func testSuppressedFactsAlwaysDropped() throws {
        let trivia = try decoded()
        let visible = trivia.visibleFacts(suppressed: ["f_cast1"])
        XCTAssertFalse(visible.contains { $0.id == "f_cast1" }, "suppressed fact must be hidden")
        XCTAssertEqual(visible.count, 3)
    }

    func testVisibleFactsOrderedByCategory() throws {
        let trivia = try decoded()
        let visible = trivia.visibleFacts(suppressed: [])
        // production (0) before casting (1) before reference (3) before other (7).
        let cats = visible.map { $0.category }
        XCTAssertEqual(cats, [.production, .casting, .reference, .other])
    }

    // MARK: - interest / topTenFacts

    private let payloadWithInterest = """
    {
      "id": "tmdb://27205",
      "type": "movie",
      "generatedAt": "2026-07-07T00:00:00Z",
      "pipelineVersion": 2,
      "attribution": [ { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } ],
      "facts": [
        { "id": "f_high1", "text": "Highest interest fact.",
          "category": "production", "spoiler": 0, "interest": 10,
          "source": { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } },
        { "id": "f_high2", "text": "Second highest interest fact.",
          "category": "casting", "spoiler": 0, "interest": 9,
          "source": { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } },
        { "id": "f_borderline", "text": "Borderline interest fact.",
          "category": "reference", "spoiler": 0, "interest": 7,
          "source": { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } },
        { "id": "f_low", "text": "Low interest fact.",
          "category": "goof", "spoiler": 0, "interest": 3,
          "source": { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } },
        { "id": "f_nointerest", "text": "No interest field at all (old-schema fact).",
          "category": "lore", "spoiler": 0,
          "source": { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } },
        { "id": "f_spoiler_high", "text": "High interest but a spoiler.",
          "category": "production", "spoiler": 1, "interest": 10,
          "source": { "name": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Inception" } }
      ]
    }
    """.data(using: .utf8)!

    func testMissingInterestFieldDecodesAsNilNotAThrow() throws {
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: payloadWithInterest)
        let noInterestFact = trivia.facts.first { $0.id == "f_nointerest" }
        XCTAssertNotNil(noInterestFact, "decode must not throw or drop the fact")
        XCTAssertNil(noInterestFact?.interest)
    }

    func testInterestFieldDecodesPresentValue() throws {
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: payloadWithInterest)
        let highFact = trivia.facts.first { $0.id == "f_high1" }
        XCTAssertEqual(highFact?.interest, 10)
    }

    func testTopTenFactsExcludesNilAndBelowThresholdInterest() throws {
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: payloadWithInterest)
        let topTen = trivia.topTenFacts(suppressed: [])
        let ids = topTen.map(\.id)
        XCTAssertFalse(ids.contains("f_low"), "interest 3 is below the >=7 threshold")
        XCTAssertFalse(ids.contains("f_nointerest"), "nil interest is never eligible for Top 10")
    }

    func testTopTenFactsIncludesPlotFacts() throws {
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: payloadWithInterest)
        XCTAssertTrue(trivia.topTenFacts(suppressed: []).map(\.id).contains("f_spoiler_high"))
    }

    func testTopTenFactsSortedDescendingByInterest() throws {
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: payloadWithInterest)
        let topTen = trivia.topTenFacts(suppressed: [])
        let scores = topTen.map { $0.interest ?? 0 }
        XCTAssertEqual(scores, scores.sorted(by: >), "must be sorted descending by interest")
        XCTAssertEqual(topTen.first?.interest, 10)
    }

    func testTopTenFactsCapsAtTen() throws {
        let manyHighFactsJSON = """
        {
          "id": "tmdb://1", "type": "movie", "generatedAt": "", "pipelineVersion": 2,
          "attribution": [],
          "facts": [
            \((1...15).map { "{ \"id\": \"f_\($0)\", \"text\": \"Fact \($0).\", \"category\": \"production\", \"spoiler\": 0, \"interest\": 8, \"source\": { \"name\": \"Wikipedia\", \"url\": \"https://w/x\" } }" }.joined(separator: ",\n"))
          ]
        }
        """.data(using: .utf8)!
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: manyHighFactsJSON)
        let topTen = trivia.topTenFacts(suppressed: [])
        XCTAssertEqual(topTen.count, 10, "15 qualifying facts must cap at 10")
    }

    func testTopTenFactsReturnsFewerThanTenWhenFewQualify() throws {
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: payloadWithInterest)
        let topTen = trivia.topTenFacts(suppressed: [])
        // f_high1 (10), f_spoiler_high (10), f_high2 (9), f_borderline (7).
        XCTAssertEqual(topTen.count, 4)
    }

    func testTopTenFactsRespectsSuppression() throws {
        let trivia = try JSONDecoder().decode(TitleTrivia.self, from: payloadWithInterest)
        let topTen = trivia.topTenFacts(suppressed: ["f_high1"])
        XCTAssertFalse(topTen.map(\.id).contains("f_high1"))
    }
}
