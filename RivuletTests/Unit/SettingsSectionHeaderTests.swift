// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsSectionHeaderTests.swift
//  RivuletTests
//
//  Appearance groups its rows with Apple-TV-style captions. A caption is a
//  SettingsRowItem, not a real collection-view section, so the one thing that
//  must never regress is focusability: a focusable caption would swallow a row's
//  focus slot, land the description panel on an id with no descriptor, and
//  Select would do nothing.
//
//  Also pins the Live TV move: those three rows have exactly one home, and their
//  ids/keys are unchanged so SettingsDescriptors still resolves them.
//

import XCTest
@testable import Rivulet

@MainActor
final class SettingsSectionHeaderTests: XCTestCase {

    private var appearance: [SettingsRowItem] { SettingsContent.rows(for: .appearance) }

    func test_headers_areNeverFocusable() {
        let headers = appearance.filter(\.isHeader)
        XCTAssertFalse(headers.isEmpty, "Appearance should be grouped by captions")
        for header in headers {
            XCTAssertFalse(header.isFocusable, "caption \(header.title) must not take focus")
            XCTAssertFalse(header.showsChevron)
            // `.info` hands back its value string; empty is what renders as nothing.
            XCTAssertTrue(header.valueText?.isEmpty ?? true, "caption \(header.title) has trailing text")
        }
    }

    func test_appearance_groupsLibraryRowsUnderLibraryHeader() {
        let titles = appearance.map(\.title)
        guard let library = titles.firstIndex(of: "Library"),
              let liveTV = titles.firstIndex(of: "Live TV") else {
            return XCTFail("missing Library / Live TV captions in \(titles)")
        }
        // "Hero", not "Library Hero" — the caption already says Library.
        XCTAssertEqual(Array(titles[(library + 1)..<liveTV]),
                       ["Hero", "Discovery Rows", "Recent Rows"])
    }

    /// Two rows are now both titled "Hero" (under HOME and under LIBRARY). They
    /// must stay distinct underneath: same key on both would silently make one
    /// of them control the other's surface.
    func test_bothHeroRows_keepDistinctIdentities() {
        let heroes = appearance.filter { $0.title == "Hero" }
        XCTAssertEqual(heroes.count, 2)
        XCTAssertEqual(Set(heroes.map(\.id)), ["homeHero", "libraryHero"])
        for hero in heroes {
            XCTAssertNotNil(SettingsDescriptorStore.descriptor(for: hero.id),
                            "\(hero.id) needs a description panel entry to be tellable apart")
        }
    }

    /// Nothing to reposition when the Discover tab is off, so the row dims
    /// instead of vanishing (the same shape as Playback's resume prompt).
    func test_discoverAboveLibraries_dimsWithDiscoverTabOff() {
        let key = "showDiscoverTab"
        let restore = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(restore, forKey: key) }

        UserDefaults.standard.set(false, forKey: key)
        guard let off = appearance.first(where: { $0.id == "discoverAboveLibraries" }) else {
            return XCTFail("row should still be listed when the Discover tab is off")
        }
        XCTAssertFalse(off.isEnabled())
        XCTAssertFalse(off.isFocusable)

        UserDefaults.standard.set(true, forKey: key)
        let on = appearance.first { $0.id == "discoverAboveLibraries" }
        XCTAssertEqual(on?.isEnabled(), true)
        XCTAssertEqual(on?.isFocusable, true)
    }

    /// The User Profiles page is retired (the sidebar switches profiles now).
    /// Its one surviving setting has to land somewhere reachable, or the launch
    /// picker becomes a write-only preference nobody can turn off.
    func test_profilePickerOnLaunch_survivedOnAppearance() {
        let row = appearance.first { $0.id == "profilePickerOnLaunch" }
        XCTAssertNotNil(row, "the launch-picker toggle lost its home")
        XCTAssertEqual(row?.isFocusable, true)
        XCTAssertNotNil(SettingsDescriptorStore.descriptor(for: "profilePickerOnLaunch"))
        XCTAssertFalse(SettingsContent.rows(for: .root).contains { $0.id == "userProfiles" },
                       "root should no longer offer the profiles page")
    }

    func test_triviaSpoilerRow_isGone() {
        XCTAssertFalse(appearance.contains { $0.id == "hideTriviaSpoilers" })
        XCTAssertNil(SettingsDescriptorStore.descriptor(for: "hideTriviaSpoilers"))
    }

    func test_liveTVAppearanceRows_moved_notDuplicated() {
        let moved = ["liveTVAboveLibraries", "defaultLayout", "classicTVMode"]
        let appearanceIDs = appearance.map(\.id)
        let liveTVIDs = SettingsContent.rows(for: .liveTV).map(\.id)
        for id in moved {
            XCTAssertTrue(appearanceIDs.contains(id), "\(id) should live on Appearance")
            XCTAssertFalse(liveTVIDs.contains(id), "\(id) should have left the Live TV page")
            XCTAssertNotNil(SettingsDescriptorStore.descriptor(for: id),
                            "\(id) lost its description panel entry")
        }
        // Playback-side Live TV rows stay put.
        XCTAssertTrue(liveTVIDs.contains("allowFourStreams"))
    }
}
