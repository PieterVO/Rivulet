//
//  InsightsTriviaPanelTests.swift
//  RivuletTests
//
//  Panel-level coverage for the Trivia section (P2a, Task 3.2) appended
//  below the cast list in `InsightsCastListView`. `TriviaFactTests` already
//  covers `visibleFacts` filtering in isolation; this proves the panel wires
//  that filtered result into the view correctly — including the
//  graceful-absent rule (no trivia / everything filtered out → section is
//  not shown at all, same as cast's empty state).
//

import XCTest
@testable import Rivulet

@MainActor
final class InsightsTriviaPanelTests: XCTestCase {

    private func makeFact(_ id: String, spoiler: Int = 0, category: TriviaCategory = .production) -> TriviaFact {
        let json = """
        { "id": "\(id)", "text": "Fact \(id).", "category": "\(category.rawValue)", "spoiler": \(spoiler),
          "source": { "name": "Wikipedia", "url": "https://w/x" } }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(TriviaFact.self, from: json)
    }

    private func makeTrivia(facts: [TriviaFact], attribution: [TriviaSource] = [TriviaSource(name: "Wikipedia", url: "https://w/x")]) -> TitleTrivia {
        let factsJSON = facts.map {
            """
            { "id": "\($0.id)", "text": "\($0.text)", "category": "\($0.category.rawValue)", "spoiler": \($0.spoiler),
              "source": { "name": "\($0.source.name)", "url": "\($0.source.url)" } }
            """
        }.joined(separator: ",")
        let attributionJSON = attribution.map { "{ \"name\": \"\($0.name)\", \"url\": \"\($0.url)\" }" }.joined(separator: ",")
        let json = """
        { "id": "tmdb://1", "type": "movie", "generatedAt": "2026-07-07T00:00:00Z", "pipelineVersion": 1,
          "attribution": [\(attributionJSON)], "facts": [\(factsJSON)] }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(TitleTrivia.self, from: json)
    }

    func test_noTrivia_sectionAbsent() {
        let list = InsightsCastListView(cast: [], trivia: nil, onSelect: { _ in })
        XCTAssertEqual(list.triviaRowCount, 0)
        XCTAssertFalse(list.hasTriviaSection)
    }

    func test_triviaWithNoFacts_sectionAbsent() {
        let trivia = makeTrivia(facts: [])
        let list = InsightsCastListView(cast: [], trivia: trivia, onSelect: { _ in })
        XCTAssertEqual(list.triviaRowCount, 0)
        XCTAssertFalse(list.hasTriviaSection)
    }

    func test_allFactsFilteredBySpoilers_sectionAbsent() {
        // Every fact is spoiler-tagged; hiding spoilers should leave nothing,
        // so the whole section (not just the rows) must vanish gracefully.
        let trivia = makeTrivia(facts: [makeFact("f1", spoiler: 1), makeFact("f2", spoiler: 2)])
        let list = InsightsCastListView(cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true, onSelect: { _ in })
        XCTAssertEqual(list.triviaRowCount, 0)
        XCTAssertFalse(list.hasTriviaSection)
    }

    func test_visibleFacts_renderAsRows() {
        let trivia = makeTrivia(facts: [makeFact("f1", spoiler: 0), makeFact("f2", spoiler: 0)])
        let list = InsightsCastListView(cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true, onSelect: { _ in })
        XCTAssertEqual(list.triviaRowCount, 2)
        XCTAssertTrue(list.hasTriviaSection)
    }

    func test_suppressedFactIsExcludedFromRows() {
        let trivia = makeTrivia(facts: [makeFact("f1", spoiler: 0), makeFact("f2", spoiler: 0)])
        let list = InsightsCastListView(cast: [], trivia: trivia, suppressedTriviaIDs: ["f2"], hideSpoilers: false, onSelect: { _ in })
        XCTAssertEqual(list.triviaRowCount, 1, "the suppressed fact must not render as a row")
    }

    func test_hideSpoilersOff_showsSpoilerFacts() {
        let trivia = makeTrivia(facts: [makeFact("f1", spoiler: 1)])
        let list = InsightsCastListView(cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: false, onSelect: { _ in })
        XCTAssertEqual(list.triviaRowCount, 1, "with hide-spoilers off, a spoiler-tagged fact must still render")
    }

    /// The container forwards its trivia args through to the list view
    /// unchanged — a thin plumbing check that the two-state container
    /// doesn't drop or mistranslate them.
    func test_containerForwardsTriviaToListView() {
        let trivia = makeTrivia(facts: [makeFact("f1", spoiler: 0)])
        let container = InsightsPanelContainerView(cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: false)
        // The container's `preferredFocusEnvironments` in `.list` state
        // returns the hosted list view; walk its subviews to find it and
        // confirm a trivia row made it through.
        let listView = container.subviews.compactMap { $0 as? InsightsCastListView }.first
        XCTAssertEqual(listView?.triviaRowCount, 1)
    }
}
