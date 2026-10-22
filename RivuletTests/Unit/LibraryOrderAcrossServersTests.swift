// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The one library order across servers (#87): Plex section keys are bare
/// ("1"), other servers' are "<providerID>/<library id>".
final class LibraryOrderAcrossServersTests: XCTestCase {
    private func arrange(_ keys: [String], saved: [String]) -> [String] {
        LibrarySettingsManager.arrange(keys, key: { $0 }, savedOrder: saved)
    }

    func test_nothingSaved_keepsServerOrder() {
        XCTAssertEqual(arrange(["1", "2", "plex:test/1"], saved: []), ["1", "2", "plex:test/1"])
    }

    func test_savedOrder_canInterleaveServers() {
        XCTAssertEqual(arrange(["1", "2", "plex:test/1"], saved: ["1", "plex:test/1", "2"]),
                       ["1", "plex:test/1", "2"])
    }

    func test_newLibrary_goesAfterItsOwnServer_notAtTheEnd() {
        // "3" is new on the selected server; the user put the test server last.
        XCTAssertEqual(arrange(["1", "2", "3", "plex:test/1"], saved: ["1", "2", "plex:test/1"]),
                       ["1", "2", "3", "plex:test/1"])
        // A new server with nothing saved goes last.
        XCTAssertEqual(arrange(["1", "jellyfin:srv/m"], saved: ["1"]), ["1", "jellyfin:srv/m"])
    }

    func test_grouping() {
        XCTAssertTrue(LibrarySettingsManager.isGroupedByServer(["plex:test/1", "1", "2", "jellyfin:srv/m"]))
        XCTAssertFalse(LibrarySettingsManager.isGroupedByServer(["1", "plex:test/1", "2"]))
        XCTAssertTrue(LibrarySettingsManager.isGroupedByServer([]))
    }
}
