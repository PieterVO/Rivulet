// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class PlexUserRatingTests: XCTestCase {
    func testUnratedIsNotFavorite() {
        XCTAssertFalse(PlexUserRating.isFavorite(nil))
        XCTAssertFalse(PlexUserRating.isFavorite(0))
    }

    // The old rule was "any rating at all", which called this a favorite.
    func testOneStarPanIsNotFavorite() {
        XCTAssertFalse(PlexUserRating.isFavorite(2))
    }

    func testThreeStarsIsNotFavorite() {
        XCTAssertFalse(PlexUserRating.isFavorite(6))
    }

    func testAboveThreeStarsIsFavorite() {
        XCTAssertTrue(PlexUserRating.isFavorite(7))   // 3.5 stars
        XCTAssertTrue(PlexUserRating.isFavorite(8))   // 4 stars
        XCTAssertTrue(PlexUserRating.isFavorite(10))  // 5 stars
    }

    func testStarsHalveThePlexScale() {
        XCTAssertEqual(PlexUserRating.stars(10), 5)
        XCTAssertNil(PlexUserRating.stars(0))
    }
}
