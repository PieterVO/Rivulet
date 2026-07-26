// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexLibraryVisibilityFilterTests.swift
//  RivuletTests
//
//  `/hubs/continueWatching` and the global `/hubs` are account-level endpoints:
//  one flat list spanning every library, with no way to scope the request.
//  Rivulet's hidden-library / shown-on-Home sets are client-side UserDefaults
//  Plex never sees, so items from a hidden library keep arriving — visibly
//  duplicated for a user with mirrored libraries ("Movies" plus a
//  "Movies.x264" re-encode of the same films). The predicate under test is the
//  only thing standing between that payload and the Home rows.
//
//  Both fail-open cases are load-bearing, not politeness: an empty key set
//  means the library list has not loaded yet (cold launch), and an
//  unattributed item is not evidence of being hidden. Getting either wrong
//  blanks Continue Watching and the hero.
//

import XCTest
@testable import Rivulet

final class PlexLibraryVisibilityFilterTests: XCTestCase {

    // MARK: - Helpers

    /// Item attributed the way Plex spells it on a hub payload: the path form
    /// of the section key plus the numeric id.
    private func item(
        ratingKey: String,
        sectionKey: String? = nil,
        sectionID: Int? = nil
    ) -> PlexMetadata {
        PlexMetadata(
            ratingKey: ratingKey,
            type: "movie",
            librarySectionID: sectionID,
            librarySectionKey: sectionKey
        )
    }

    // MARK: - Section id normalization

    func test_normalizedSectionID_stripsPlexSectionPath() {
        // Plex writes `librarySectionKey` as a path but `PlexLibrary.key` as the
        // bare id; without normalizing, the two never compare equal.
        XCTAssertEqual(PlexLibraryVisibilityFilter.normalizedSectionID("/library/sections/3"), "3")
    }

    func test_normalizedSectionID_passesBareIDThrough() {
        XCTAssertEqual(PlexLibraryVisibilityFilter.normalizedSectionID("3"), "3")
    }

    func test_normalizedKeySet_acceptsBothSpellings() {
        let keys = PlexLibraryVisibilityFilter.normalizedKeySet(["1", "/library/sections/2"])
        XCTAssertEqual(keys, ["1", "2"])
    }

    // MARK: - Matching

    func test_matchesByLibrarySectionKey() {
        let keys = PlexLibraryVisibilityFilter.normalizedKeySet(["1"])
        XCTAssertTrue(
            PlexLibraryVisibilityFilter.isVisible(
                item(ratingKey: "100", sectionKey: "/library/sections/1"),
                in: keys
            )
        )
    }

    func test_matchesByStringifiedLibrarySectionID() {
        // No section key on the item — the numeric id is the only attribution.
        let keys = PlexLibraryVisibilityFilter.normalizedKeySet(["7"])
        XCTAssertTrue(
            PlexLibraryVisibilityFilter.isVisible(item(ratingKey: "100", sectionID: 7), in: keys)
        )
    }

    func test_excludesItemFromUnlistedSection() {
        let keys = PlexLibraryVisibilityFilter.normalizedKeySet(["1"])
        XCTAssertFalse(
            PlexLibraryVisibilityFilter.isVisible(
                item(ratingKey: "200", sectionKey: "/library/sections/9", sectionID: 9),
                in: keys
            )
        )
    }

    func test_sectionKeyWins_whenBothFieldsPresent() {
        // The key is the more specific field; the id is only a fallback. If the
        // key says "hidden", a stale/container-inherited id must not override.
        let keys = PlexLibraryVisibilityFilter.normalizedKeySet(["1"])
        XCTAssertFalse(
            PlexLibraryVisibilityFilter.isVisible(
                item(ratingKey: "200", sectionKey: "/library/sections/9", sectionID: 1),
                in: keys
            )
        )
    }

    // MARK: - Fail open

    func test_failsOpen_onEmptyKeySet() {
        // Cold launch: libraries have not loaded. Filtering here would blank
        // Continue Watching and the hero on every launch.
        XCTAssertTrue(
            PlexLibraryVisibilityFilter.isVisible(
                item(ratingKey: "100", sectionKey: "/library/sections/9", sectionID: 9),
                in: []
            )
        )
    }

    func test_failsOpen_onUnattributedItem() {
        let keys = PlexLibraryVisibilityFilter.normalizedKeySet(["1"])
        XCTAssertTrue(PlexLibraryVisibilityFilter.isVisible(item(ratingKey: "100"), in: keys))
    }

    func test_filter_returnsInputUnchanged_whenKeySetEmpty() {
        let items = [
            item(ratingKey: "1", sectionKey: "/library/sections/1"),
            item(ratingKey: "2", sectionKey: "/library/sections/9")
        ]
        let out = PlexLibraryVisibilityFilter.filter(items, toLibraryKeys: [String]())
        XCTAssertEqual(out.map { $0.ratingKey }, ["1", "2"])
    }

    // MARK: - The reported bug

    func test_excludesHiddenMirrorLibrary_keepingOnlyTheVisibleCopy() {
        // Section 1 = "Movies", section 2 = "Movies.x264" (a low-bitrate
        // re-encode of the same films, hidden by the user). The account-level
        // hub returns both copies of every title; only the visible one may
        // survive, and the pairs must not collapse into one another.
        let hub = [
            item(ratingKey: "10", sectionKey: "/library/sections/1", sectionID: 1),  // Dune, Movies
            item(ratingKey: "11", sectionKey: "/library/sections/2", sectionID: 2),  // Dune, x264
            item(ratingKey: "12", sectionKey: "/library/sections/1", sectionID: 1),  // Arrival, Movies
            item(ratingKey: "13", sectionKey: "/library/sections/2", sectionID: 2)   // Arrival, x264
        ]

        let visible = PlexLibraryVisibilityFilter.filter(hub, toLibraryKeys: ["1"])

        XCTAssertEqual(visible.map { $0.ratingKey }, ["10", "12"])
    }

    func test_hidingEveryLibraryLeavesNothing() {
        // Distinct from the empty-key-set fail-open: a NON-empty key set that
        // simply matches nothing must genuinely produce no row, or the
        // `!visible.isEmpty` guard in `projectHomeItems()` never fires.
        let hub = [item(ratingKey: "10", sectionKey: "/library/sections/2", sectionID: 2)]
        XCTAssertTrue(PlexLibraryVisibilityFilter.filter(hub, toLibraryKeys: ["1"]).isEmpty)
    }

    func test_unattributedItemSurvivesAlongsideFilteredOnes() {
        let hub = [
            item(ratingKey: "10", sectionKey: "/library/sections/1", sectionID: 1),
            item(ratingKey: "11", sectionKey: "/library/sections/2", sectionID: 2),
            item(ratingKey: "12")  // no attribution at all
        ]
        let visible = PlexLibraryVisibilityFilter.filter(hub, toLibraryKeys: ["1"])
        XCTAssertEqual(visible.map { $0.ratingKey }, ["10", "12"])
    }
}
