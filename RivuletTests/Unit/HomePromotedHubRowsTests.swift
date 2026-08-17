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

    /// The row `/hubs` promotes. It must be recognised from its OWN identifier:
    /// the two endpoints disagree (`/hubs` says `home.continue`,
    /// `/hubs/continueWatching` says `continueWatching`), and testing one
    /// against the other matched nothing, which shipped the row as a plain
    /// poster shelf instead of the backdrop-and-logo resume tiles.
    func test_homeContinue_isContinueWatching() {
        XCTAssertTrue(PlexDataStore.isContinueWatchingFamily(hubIdentifier: "home.continue"))
    }

    /// The dedicated endpoint's own identifier, which is a different string.
    func test_dedicatedEndpointIdentifier_isContinueWatching() {
        XCTAssertTrue(PlexDataStore.isContinueWatchingFamily(hubIdentifier: "continueWatching"))
    }

    /// On Deck is in the family on purpose. Plex merged the concepts, the rows
    /// share most of their items, and the projection collapses them into one.
    func test_onDeck_isInTheFamily() {
        XCTAssertTrue(PlexDataStore.isContinueWatchingFamily(hubIdentifier: "home.ondeck"))
    }

    /// A library's own in-progress hub, for the library-page path.
    func test_libraryInProgressHub_isInTheFamily() {
        XCTAssertTrue(PlexDataStore.isContinueWatchingFamily(hubIdentifier: "movie.inprogress.1"))
    }

    func test_ordinaryRows_areNotInTheFamily() {
        for id in ["home.movies.recent", "home.television.recent", "home.playlists",
                   "movie.topunwatched.1", "home.music.recent"] {
            XCTAssertFalse(PlexDataStore.isContinueWatchingFamily(hubIdentifier: id), id)
        }
    }

    func test_missingIdentifier_isNotInTheFamily() {
        XCTAssertFalse(PlexDataStore.isContinueWatchingFamily(hubIdentifier: nil))
        XCTAssertFalse(PlexDataStore.isContinueWatchingFamily(hubIdentifier: ""))
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

    // MARK: - Which libraries contribute a Home row

    /// `hidden` is Plex's own per-user pin state and the ONLY thing that decides
    /// which libraries contribute a Home row. Measured on a live PMS 1.43.3:
    /// the six `hidden == 0` libraries were exactly the six with a Home-promoted
    /// hub; the seven hidden ones had none.
    func test_pinState_readsHiddenFromTheServer() {
        func library(_ key: String, hidden: Int?) -> PlexLibrary {
            PlexLibrary(key: key, type: "movie", title: key, agent: "a", scanner: "s",
                        language: "en", uuid: key, updatedAt: nil, createdAt: nil,
                        scannedAt: nil, Location: nil, hidden: hidden)
        }
        XCTAssertTrue(library("1", hidden: 0).isPinnedToHome)
        XCTAssertFalse(library("5", hidden: 1).isPinnedToHome, "1 = hidden from Home, kept in the sidebar")
        XCTAssertFalse(library("16", hidden: 2).isPinnedToHome, "2 = hidden from Home and the sidebar")
    }

    /// A server that omits the field entirely must not blank Home.
    func test_absentHidden_countsAsPinned() {
        let library = PlexLibrary(key: "1", type: "show", title: "TV", agent: "a", scanner: "s",
                                  language: "en", uuid: "u", updatedAt: nil, createdAt: nil,
                                  scannedAt: nil, Location: nil)
        XCTAssertNil(library.hidden)
        XCTAssertTrue(library.isPinnedToHome)
    }

    func test_hiddenDecodesFromLibrarySections() throws {
        let json = """
        {"key":"4","type":"artist","title":"Audio Books","agent":"a","scanner":"s",
         "language":"en","uuid":"u","hidden":1}
        """.data(using: .utf8)!
        let library = try JSONDecoder().decode(PlexLibrary.self, from: json)
        XCTAssertEqual(library.hidden, 1)
        XCTAssertFalse(library.isPinnedToHome)
    }

    // MARK: - What order those rows come out in

    private func library(_ key: String, hidden: Int = 0) -> PlexLibrary {
        PlexLibrary(key: key, type: "movie", title: key, agent: "a", scanner: "s",
                    language: "en", uuid: key, updatedAt: nil, createdAt: nil,
                    scannedAt: nil, Location: nil, hidden: hidden)
    }

    /// Issue #295: the right rows, the wrong order. `/library/sections` comes
    /// back in the server's order, and Plex's rule is that the app's own sidebar
    /// order decides Home's row order (that order is per app install, never
    /// server-side). `librariesPinnedToHome` gets both the order and the
    /// sidebar filter by deriving from `visibleLibraries`, so this is the piece
    /// that has to hold: reorder wins, and anything the user hasn't placed keeps
    /// its server position at the end rather than vanishing.
    @MainActor
    func test_sortLibraries_appliesSidebarOrderAndKeepsUnplacedOnesAtTheEnd() {
        let mgr = LibrarySettingsManager.shared
        let saved = mgr.libraryOrder
        defer { mgr.libraryOrder = saved }

        let serverOrder = [library("1"), library("2"), library("3"), library("4")]

        mgr.libraryOrder = []
        XCTAssertEqual(mgr.sortLibraries(serverOrder).map(\.key), ["1", "2", "3", "4"],
                       "no stored order = the server's order, so a fresh install is unchanged")

        mgr.libraryOrder = ["3", "1"]
        XCTAssertEqual(mgr.sortLibraries(serverOrder).map(\.key), ["3", "1", "2", "4"])

        mgr.libraryOrder = ["9", "2"]
        XCTAssertEqual(mgr.sortLibraries(serverOrder).map(\.key), ["2", "1", "3", "4"],
                       "a key for a library that is gone is inert, not a dropped row")
    }

    /// The other half of #295: one "hidden" means hidden. A library switched off
    /// in Settings → Libraries used to keep its Home rows, because the
    /// projection read Plex's pin state and ignored Rivulet's sidebar set, so
    /// hiding "Kids Movies" left "Recently Added in Kids Movies" on Home.
    /// Both gates now have to pass, and neither can add a library the other
    /// excluded.
    @MainActor
    func test_librariesPinnedToHome_needsBothPlexPinAndSidebarVisibility() {
        let store = PlexDataStore.shared
        let mgr = LibrarySettingsManager.shared
        let savedLibraries = store.libraries
        let savedHidden = mgr.hiddenLibraryKeys
        let savedOrder = mgr.libraryOrder
        defer {
            store.libraries = savedLibraries
            mgr.hiddenLibraryKeys = savedHidden
            mgr.libraryOrder = savedOrder
        }

        mgr.libraryOrder = []
        mgr.hiddenLibraryKeys = []
        store.libraries = [
            library("1"),              // pinned in Plex, shown here
            library("2"),              // pinned in Plex, hidden here
            library("3", hidden: 1),   // unpinned in Plex, shown here
        ]

        XCTAssertEqual(store.librariesPinnedToHome.map(\.key), ["1", "2"],
                       "Plex's pin alone decides the candidate set")

        mgr.hiddenLibraryKeys = ["2"]
        XCTAssertEqual(store.librariesPinnedToHome.map(\.key), ["1"],
                       "hiding a library in the sidebar takes its Home rows with it")

        mgr.hiddenLibraryKeys = []
        mgr.libraryOrder = ["3", "2", "1"]
        XCTAssertEqual(store.librariesPinnedToHome.map(\.key), ["2", "1"],
                       "the sidebar order applies, and cannot promote a library Plex left unpinned")
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
