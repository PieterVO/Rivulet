// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomeLibraryChangePollTests.swift
//  RivuletTests
//
//  The change token behind Home's 30s Recently Added poll (#315): the newest
//  `/library/recentlyAdded` item's identity, factored out of `PlexDataStore`.
//

import XCTest
@testable import Rivulet

final class HomeLibraryChangePollTests: XCTestCase {

    private func item(ratingKey: String?, addedAt: Int?, updatedAt: Int?) -> PlexMetadata {
        var meta = PlexMetadata()
        meta.ratingKey = ratingKey
        meta.addedAt = addedAt
        meta.updatedAt = updatedAt
        return meta
    }

    func test_stampIsNil_whenTheServerReturnedNothing() {
        // No item means no baseline to compare, never "everything changed".
        XCTAssertNil(PlexDataStore.recentlyAddedStamp(nil))
    }

    func test_stampIsNil_withoutARatingKey() {
        XCTAssertNil(PlexDataStore.recentlyAddedStamp(item(ratingKey: nil, addedAt: 1, updatedAt: 2)))
    }

    func test_sameItemProducesTheSameStamp() {
        let a = PlexDataStore.recentlyAddedStamp(item(ratingKey: "241695", addedAt: 100, updatedAt: 101))
        let b = PlexDataStore.recentlyAddedStamp(item(ratingKey: "241695", addedAt: 100, updatedAt: 101))
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    func test_newItemChangesTheStamp() {
        let before = PlexDataStore.recentlyAddedStamp(item(ratingKey: "241695", addedAt: 100, updatedAt: 101))
        let after = PlexDataStore.recentlyAddedStamp(item(ratingKey: "241700", addedAt: 200, updatedAt: 201))
        XCTAssertNotEqual(before, after)
    }

    /// The case `ratingKey` alone misses: a new episode lands in the season that
    /// is already newest, so the key is unchanged and only the stamps move.
    func test_episodeAddedToTheAlreadyNewestSeasonChangesTheStamp() {
        let before = PlexDataStore.recentlyAddedStamp(item(ratingKey: "241695", addedAt: 100, updatedAt: 101))
        let after = PlexDataStore.recentlyAddedStamp(item(ratingKey: "241695", addedAt: 100, updatedAt: 500))
        XCTAssertNotEqual(before, after)
    }

    func test_missingTimestampsDoNotCollideWithRealOnes() {
        let absent = PlexDataStore.recentlyAddedStamp(item(ratingKey: "1", addedAt: nil, updatedAt: nil))
        let zeroed = PlexDataStore.recentlyAddedStamp(item(ratingKey: "1", addedAt: 0, updatedAt: 0))
        let real = PlexDataStore.recentlyAddedStamp(item(ratingKey: "1", addedAt: 100, updatedAt: 101))
        XCTAssertEqual(absent, zeroed, "absent and zero both mean 'no timestamp'")
        XCTAssertNotEqual(absent, real)
    }
}
