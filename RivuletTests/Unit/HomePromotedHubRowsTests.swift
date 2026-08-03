// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomePromotedHubRowsTests.swift
//  RivuletTests
//
//  Home renders the Plex server's promoted hub set (`/hubs`) rather than a row
//  set Rivulet composes. `PlexDataStore` is a `private init()` singleton wired
//  to shared network/cache/auth managers, so `projectHomeItems()` is not
//  reachable from a unit test (same constraint `HomeRecentlyAddedCarryOverTests`
//  documents). The two decisions in that loop that can actually be wrong are
//  factored out as pure statics, and those are what these cover.
//
//  Both are grounded in a live PMS 1.43.3 `/hubs` response.
//

import XCTest
@testable import Rivulet

final class HomePromotedHubRowsTests: XCTestCase {

    // MARK: - Continue Watching identity

    /// The server names the row: whatever `/hubs/continueWatching` identifies
    /// itself as is the Continue Watching row in `/hubs`.
    func test_continueWatching_matchesTheDedicatedHubsIdentifier() {
        XCTAssertTrue(PlexDataStore.isContinueWatchingRow(
            hubIdentifier: "home.continue", continueWatchingIdentifier: "home.continue"))
    }

    /// On Deck is a SEPARATE promoted row on the same home payload. Folding it
    /// into Continue Watching would give it resume-style tiles and let the
    /// fast-refresh fetch overwrite its items with the wrong list.
    func test_onDeck_isNotContinueWatching() {
        XCTAssertFalse(PlexDataStore.isContinueWatchingRow(
            hubIdentifier: "home.ondeck", continueWatchingIdentifier: "home.continue"))
    }

    func test_ordinaryRow_isNotContinueWatching() {
        XCTAssertFalse(PlexDataStore.isContinueWatchingRow(
            hubIdentifier: "home.movies.recent", continueWatchingIdentifier: "home.continue"))
    }

    /// Before the dedicated fetch lands there is nothing to match against, so
    /// the literal is the fallback. It must still not claim On Deck.
    func test_fallsBackToTheLiteral_whenTheDedicatedHubHasNotLoaded() {
        XCTAssertTrue(PlexDataStore.isContinueWatchingRow(
            hubIdentifier: "home.continue", continueWatchingIdentifier: nil))
        XCTAssertFalse(PlexDataStore.isContinueWatchingRow(
            hubIdentifier: "home.ondeck", continueWatchingIdentifier: nil))
    }

    func test_missingIdentifier_isNeverContinueWatching() {
        XCTAssertFalse(PlexDataStore.isContinueWatchingRow(
            hubIdentifier: nil, continueWatchingIdentifier: nil))
        XCTAssertFalse(PlexDataStore.isContinueWatchingRow(
            hubIdentifier: "", continueWatchingIdentifier: "home.continue"))
    }

    // MARK: - Pagination key

    /// The trap: most `/hubs` rows carry no `hubKey` and a `key` that is a
    /// literal id list. Paging against that re-fetches the items already on
    /// screen instead of the next page.
    func test_idListKey_isNotPaginable() {
        XCTAssertNil(PlexDataStore.paginableHubKey(
            hubKey: nil, key: "/library/metadata/209601,209469,209387"))
    }

    func test_realHubPath_isPaginable() {
        XCTAssertEqual(
            PlexDataStore.paginableHubKey(hubKey: nil, key: "/hubs/home/recentlyAdded?type=13"),
            "/hubs/home/recentlyAdded?type=13")
    }

    func test_hubKeyWins_overKey() {
        XCTAssertEqual(
            PlexDataStore.paginableHubKey(hubKey: "/hubs/sections/1/recentlyAdded",
                                          key: "/library/metadata/1,2,3"),
            "/hubs/sections/1/recentlyAdded")
    }

    /// A `hubKey` that isn't a hub path must not be preferred just for being
    /// first; fall through and then refuse.
    func test_nonHubPaths_areRefused() {
        XCTAssertNil(PlexDataStore.paginableHubKey(hubKey: "/library/sections/1/all", key: nil))
        XCTAssertNil(PlexDataStore.paginableHubKey(hubKey: nil, key: nil))
    }

    // MARK: - Decoding

    /// `promoted` has to survive decoding or every row is filtered on nil.
    func test_promotedFlagDecodes() throws {
        let json = """
        {"hubIdentifier":"home.movies.recent","title":"Recently Added Movies","promoted":true}
        """.data(using: .utf8)!
        let hub = try JSONDecoder().decode(PlexHub.self, from: json)
        XCTAssertEqual(hub.promoted, true)
        XCTAssertEqual(hub.title, "Recently Added Movies")
    }

    /// Library-page hubs carry no `promoted`. Nil must not read as false, or
    /// library pages would render nothing.
    func test_absentPromotedDecodesAsNil() throws {
        let json = """
        {"hubIdentifier":"movie.topunwatched.1","title":"Top Unwatched Movies"}
        """.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(PlexHub.self, from: json).promoted)
    }
}
