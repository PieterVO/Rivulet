// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomeRecentlyAddedCarryOverTests.swift
//  RivuletTests
//
//  A library whose hub fetch times out keeps its cached Recently Added row; only
//  a library that answered with no content may drop it (#236).
//

import XCTest
@testable import Rivulet

final class HomeRecentlyAddedCarryOverTests: XCTestCase {

    // MARK: - Carry over (library never answered)

    func test_carriesOver_whenLibraryNeverLoaded() {
        // nil hubs, no recorded failure: the fetch has not landed yet.
        XCTAssertTrue(PlexDataStore.shouldCarryOverRecentlyAddedRow(hubs: nil, fetchFailed: false))
    }

    func test_carriesOver_whenFetchFailedAndNothingCached() {
        XCTAssertTrue(PlexDataStore.shouldCarryOverRecentlyAddedRow(hubs: nil, fetchFailed: true))
    }

    func test_carriesOver_whenFetchFailedDespiteStaleHubsInMemory() {
        // The regression nil-ness alone misses: a failed refresh leaves the
        // previous pass's hubs behind, so `hubs != nil` is not proof the
        // library answered THIS pass.
        let stale = [PlexHub(hubIdentifier: "genre", title: "By Genre", Metadata: [])]
        XCTAssertTrue(PlexDataStore.shouldCarryOverRecentlyAddedRow(hubs: stale, fetchFailed: true))
    }

    // MARK: - Omit (library answered, genuinely has nothing)

    func test_omits_whenLibraryAnsweredWithNoRecentlyAddedHub() {
        let hubs = [PlexHub(hubIdentifier: "library.genre", title: "By Genre")]
        XCTAssertFalse(PlexDataStore.shouldCarryOverRecentlyAddedRow(hubs: hubs, fetchFailed: false))
    }

    func test_omits_whenLibraryAnsweredWithEmptyHubList() {
        XCTAssertFalse(PlexDataStore.shouldCarryOverRecentlyAddedRow(hubs: [], fetchFailed: false))
    }

    func test_omits_whenLibraryAnsweredWithEmptyRecentlyAddedHub() {
        let hubs = [PlexHub(hubIdentifier: "library.recentlyAdded", title: "Recently Added", Metadata: [])]
        XCTAssertFalse(PlexDataStore.shouldCarryOverRecentlyAddedRow(hubs: hubs, fetchFailed: false))
    }

    // MARK: - Row identity

    func test_rowID_matchesProjectionIDFormat() {
        // Must equal the id `projectHomeItems()` writes, or a carried-over row
        // would never be found in the previously projected rail.
        XCTAssertEqual(
            PlexDataStore.recentlyAddedRowID(forLibraryKey: "/library/sections/3"),
            "hub:/library/sections/3:recent"
        )
    }

    // MARK: - Continue Watching (the row dropped out of Home around 3 s after launch)

    func test_continueWatching_carriesOverUntilItsFirstFetch() {
        XCTAssertTrue(PlexDataStore.carriesOverContinueWatching(hasFetched: false, isHidden: false))
    }

    func test_continueWatching_isDroppedOnceAFetchSaysThereIsNone() {
        // Otherwise a stale row re-persists itself on every projection.
        XCTAssertFalse(PlexDataStore.carriesOverContinueWatching(hasFetched: true, isHidden: false))
    }

    func test_continueWatching_hiddenRowIsNotCarried() {
        XCTAssertFalse(PlexDataStore.carriesOverContinueWatching(hasFetched: false, isHidden: true))
    }

    func test_rowID_isStablePerLibrary() {
        let movies = PlexDataStore.recentlyAddedRowID(forLibraryKey: "/library/sections/1")
        let bollywood = PlexDataStore.recentlyAddedRowID(forLibraryKey: "/library/sections/7")
        XCTAssertNotEqual(movies, bollywood)
        XCTAssertEqual(movies, PlexDataStore.recentlyAddedRowID(forLibraryKey: "/library/sections/1"))
    }
}
