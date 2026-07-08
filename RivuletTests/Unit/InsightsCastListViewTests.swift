//
//  InsightsCastListViewTests.swift
//  RivuletTests
//
//  Tab-scoped row building for the Insights panel's list view.
//

import XCTest
@testable import Rivulet

final class InsightsCastListViewTests: XCTestCase {

    private func fact(id: String, category: TriviaCategory, interest: Int? = nil) -> TriviaFact {
        let json = """
        { "id": "\(id)", "text": "Fact text.", "category": "\(category.rawValue)", "spoiler": 0,
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

    func testInitialTabCastShowsOnlyCastRows() {
        let cast = [MediaPerson(id: "1", name: "Actor One", role: nil, imageURL: nil)]
        let trivia = trivia(facts: [fact(id: "f1", category: .production, interest: 8)])
        let view = InsightsCastListView(
            cast: cast, trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true,
            initialTab: .cast, onSelectCast: { _ in })
        XCTAssertEqual(view.triviaRowCount, 0)
        XCTAssertEqual(view.castRowCount, 1)
    }

    func testInitialTabCategoryShowsOnlyThatCategorysFacts() {
        let trivia = trivia(facts: [
            fact(id: "f1", category: .production, interest: 8),
            fact(id: "f2", category: .casting, interest: 8),
        ])
        let view = InsightsCastListView(
            cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true,
            initialTab: .category(.production), onSelectCast: { _ in })
        XCTAssertEqual(view.triviaRowCount, 1)
        XCTAssertEqual(view.castRowCount, 0)
    }

    func testInitialTabTopTenShowsOnlyQualifyingFacts() {
        let trivia = trivia(facts: [
            fact(id: "f1", category: .production, interest: 9),
            fact(id: "f2", category: .casting, interest: 3),
        ])
        let view = InsightsCastListView(
            cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true,
            initialTab: .topTen, onSelectCast: { _ in })
        XCTAssertEqual(view.triviaRowCount, 1)
    }

    func testSetTabRebuildsRowsForNewTab() {
        let cast = [MediaPerson(id: "1", name: "Actor One", role: nil, imageURL: nil)]
        let trivia = trivia(facts: [fact(id: "f1", category: .production, interest: 8)])
        let view = InsightsCastListView(
            cast: cast, trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true,
            initialTab: .cast, onSelectCast: { _ in })
        XCTAssertEqual(view.castRowCount, 1)
        XCTAssertEqual(view.triviaRowCount, 0)

        view.setTab(.category(.production))
        XCTAssertEqual(view.castRowCount, 0)
        XCTAssertEqual(view.triviaRowCount, 1)
    }
}
