// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsTabTests.swift
//  RivuletTests
//
//  Tab-set derivation for the Insights panel's pill bar — pure logic, no
//  view instantiation needed.
//

import XCTest
@testable import Rivulet

final class InsightsTabTests: XCTestCase {

    private func fact(id: String, category: TriviaCategory, spoiler: Int = 0, interest: Int? = nil) -> TriviaFact {
        let json = """
        { "id": "\(id)", "text": "Fact text.", "category": "\(category.rawValue)", "spoiler": \(spoiler),
          \(interest.map { "\"interest\": \($0)," } ?? "")
          "source": { "name": "Wikipedia", "url": "https://w/x" } }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(TriviaFact.self, from: json)
    }

    private func trivia(facts: [TriviaFact]) -> TitleTrivia {
        let factsJSON = try! JSONEncoder().encode(facts)
        let factsString = String(data: factsJSON, encoding: .utf8)!
        let json = """
        { "id": "tmdb://1", "type": "movie", "generatedAt": "", "pipelineVersion": 2,
          "attribution": [], "facts": \(factsString) }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(TitleTrivia.self, from: json)
    }

    func testNoCastNoTriviaYieldsNoTabs() {
        let tabs = InsightsTab.availableTabs(cast: [], trivia: nil, suppressedTriviaIDs: [], hideSpoilers: true)
        XCTAssertTrue(tabs.isEmpty)
    }

    func testCastOnlyYieldsOnlyCastTab() {
        let cast = [MediaPerson(id: "1", name: "Actor", role: nil, imageURL: nil)]
        let tabs = InsightsTab.availableTabs(cast: cast, trivia: nil, suppressedTriviaIDs: [], hideSpoilers: true)
        XCTAssertEqual(tabs, [.cast])
    }

    func testTopTenTabOmittedWhenNoFactQualifies() {
        let trivia = trivia(facts: [fact(id: "f1", category: .production, interest: 3)])
        let tabs = InsightsTab.availableTabs(cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true)
        XCTAssertFalse(tabs.contains(.topTen))
        XCTAssertTrue(tabs.contains(.category(.production)))
    }

    func testTopTenTabPresentWhenAFactQualifies() {
        let trivia = trivia(facts: [fact(id: "f1", category: .production, interest: 8)])
        let tabs = InsightsTab.availableTabs(cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true)
        XCTAssertTrue(tabs.contains(.topTen))
    }

    func testTabOrderIsTopTenThenCastThenCategoryDeclarationOrder() {
        let cast = [MediaPerson(id: "1", name: "Actor", role: nil, imageURL: nil)]
        let trivia = trivia(facts: [
            fact(id: "f1", category: .music, interest: 8),
            fact(id: "f2", category: .production, interest: 8),
            fact(id: "f3", category: .casting, interest: 3),
        ])
        let tabs = InsightsTab.availableTabs(cast: cast, trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true)
        XCTAssertEqual(tabs, [.topTen, .cast, .category(.production), .category(.casting), .category(.music)])
    }

    func testCategoryWithZeroVisibleFactsAfterFilteringGetsNoTab() {
        // Only fact in .goof is a spoiler; hideSpoilers=true filters it out entirely.
        let trivia = trivia(facts: [fact(id: "f1", category: .goof, spoiler: 1, interest: 8)])
        let tabs = InsightsTab.availableTabs(cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true)
        XCTAssertTrue(tabs.isEmpty, "the only fact is spoiler-filtered out, so no category tab and no Top 10 tab should appear")
    }

    func testSuppressedFactExcludedFromTabAvailability() {
        let trivia = trivia(facts: [fact(id: "f1", category: .lore, interest: 8)])
        let tabs = InsightsTab.availableTabs(cast: [], trivia: trivia, suppressedTriviaIDs: ["f1"], hideSpoilers: true)
        XCTAssertTrue(tabs.isEmpty)
    }

    func testTitleForTab() {
        XCTAssertEqual(InsightsTab.topTen.title, "Top 10")
        XCTAssertEqual(InsightsTab.cast.title, "Cast")
        XCTAssertEqual(InsightsTab.category(.production).title, "Production")
        XCTAssertEqual(InsightsTab.category(.other).title, "Trivia")
    }
}
