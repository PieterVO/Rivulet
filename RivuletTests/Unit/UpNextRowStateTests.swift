//
//  UpNextRowStateTests.swift
//  RivuletTests
//
//  Pure-logic tests for UpNextRowState.state(for:in:currentRatingKey:) —
//  row status derivation for the Up Next panel.
//

import XCTest
@testable import Rivulet

final class UpNextRowStateTests: XCTestCase {

    private func episode(key: String, index: Int, viewCount: Int? = nil) -> PlexMetadata {
        var m = PlexMetadata()
        m.ratingKey = key
        m.index = index
        m.type = "episode"
        m.viewCount = viewCount
        return m
    }

    func test_states_aroundCurrentEpisode() {
        let eps = [
            episode(key: "1", index: 1, viewCount: 1),
            episode(key: "2", index: 2, viewCount: 1),
            episode(key: "3", index: 3),
            episode(key: "4", index: 4),
            episode(key: "5", index: 5)
        ]

        XCTAssertEqual(UpNextRowState.state(for: eps[0], in: eps, currentRatingKey: "3"), .watched)
        XCTAssertEqual(UpNextRowState.state(for: eps[1], in: eps, currentRatingKey: "3"), .watched)
        XCTAssertEqual(UpNextRowState.state(for: eps[2], in: eps, currentRatingKey: "3"), .nowPlaying)
        XCTAssertEqual(UpNextRowState.state(for: eps[3], in: eps, currentRatingKey: "3"), .upNext)
        XCTAssertEqual(UpNextRowState.state(for: eps[4], in: eps, currentRatingKey: "3"), .future)
    }

    func test_nowPlaying_winsOverWatchHistory() {
        // A rewatch: the currently playing episode has a positive viewCount
        // from a prior watch, but its position wins — it must read as
        // nowPlaying, not watched.
        let eps = [
            episode(key: "1", index: 1, viewCount: 1),
            episode(key: "2", index: 2, viewCount: 1)
        ]

        XCTAssertEqual(UpNextRowState.state(for: eps[1], in: eps, currentRatingKey: "2"), .nowPlaying)
    }

    func test_noCurrentRatingKey_watchedFallsBackToViewCount() {
        let eps = [
            episode(key: "4", index: 1, viewCount: 1),
            episode(key: "5", index: 2)
        ]

        XCTAssertEqual(UpNextRowState.state(for: eps[0], in: eps, currentRatingKey: nil), .watched)
        XCTAssertEqual(UpNextRowState.state(for: eps[1], in: eps, currentRatingKey: nil), .future)
    }
}
