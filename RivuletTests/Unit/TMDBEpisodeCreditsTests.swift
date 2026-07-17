// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class TMDBEpisodeCreditsTests: XCTestCase {

    private let fixture = """
    {
    "cast": [
    {"id": 17419, "name": "Bryan Cranston", "character": "Walter White", "profile_path": "/aXf.jpg"},
    {"id": 84497, "name": "Aaron Paul", "character": "Jesse Pinkman", "profile_path": null}
    ],
    "guest_stars": [
    {"id": 92495, "name": "John Koyama", "character": "Emilio Koyama", "profile_path": "/qQx.jpg"},
    {"id": 84497, "name": "Aaron Paul", "character": "Jesse Pinkman", "profile_path": null}
    ]
    }
    """

    func testMergedEpisodeCastDedupesByPersonId() throws {
        let data = try XCTUnwrap(fixture.data(using: .utf8))
        let response = try JSONDecoder().decode(TMDBEpisodeCreditsResponse.self, from: data)
        let merged = TMDBClient.mergedEpisodeCast(response)
        XCTAssertEqual(merged.count, 3, "Expected 3 deduped cast members")
        XCTAssertEqual(merged[0].name, "Bryan Cranston")
        XCTAssertEqual(merged[1].name, "Aaron Paul")
        XCTAssertEqual(merged[2].name, "John Koyama", "John Koyama should be last (guest)")
    }

    func testMergedEpisodeCastEmptyResponse() {
        let response = TMDBEpisodeCreditsResponse(cast: nil, guestStars: nil)
        let merged = TMDBClient.mergedEpisodeCast(response)
        XCTAssertEqual(merged.count, 0)
    }

    func testMergedEpisodeCastOnlyCast() {
        let cast = [
            TMDBCredit(id: 1, name: "Alice", job: nil, department: nil, character: "A", profilePath: nil),
            TMDBCredit(id: 2, name: "Bob", job: nil, department: nil, character: "B", profilePath: nil)
        ]
        let response = TMDBEpisodeCreditsResponse(cast: cast, guestStars: nil)
        let merged = TMDBClient.mergedEpisodeCast(response)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].name, "Alice")
        XCTAssertEqual(merged[1].name, "Bob")
    }

    func testMergedEpisodeCastOnlyGuests() {
        let guests = [
            TMDBCredit(id: 3, name: "Carol", job: nil, department: nil, character: "C", profilePath: nil)
        ]
        let response = TMDBEpisodeCreditsResponse(cast: nil, guestStars: guests)
        let merged = TMDBClient.mergedEpisodeCast(response)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].name, "Carol")
    }
}
