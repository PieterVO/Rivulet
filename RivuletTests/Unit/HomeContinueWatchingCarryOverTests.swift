// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomeContinueWatchingCarryOverTests.swift
//  RivuletTests
//
//  The cached Continue Watching row stays until the first fetch says there is none (#236).
//

import XCTest
@testable import Rivulet

final class HomeContinueWatchingCarryOverTests: XCTestCase {

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
}
