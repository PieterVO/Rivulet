// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexPlaylistRequestTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class PlexPlaylistRequestTests: XCTestCase {
    private let server = "https://srv:32400"

    private func query(_ url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func test_create_buildsTypeTitleSmartUri() throws {
        let uri = PlexNetworkManager.libraryURI(machineIdentifier: "M", ratingKeys: ["1", "2"])
        let url = try XCTUnwrap(PlexNetworkManager.createPlaylistURL(
            serverURL: server, type: "video", title: "Road Trip", uri: uri
        ))
        XCTAssertEqual(url.path, "/playlists")
        let q = query(url)
        XCTAssertEqual(q["type"], "video")
        XCTAssertEqual(q["title"], "Road Trip")
        XCTAssertEqual(q["smart"], "0")
        XCTAssertEqual(q["uri"], "server://M/com.plexapp.plugins.library/library/metadata/1,2")
        XCTAssertTrue(url.absoluteString.contains("title=Road%20Trip"))
    }

    func test_create_encodesPlusInTitle() throws {
        let url = try XCTUnwrap(PlexNetworkManager.createPlaylistURL(
            serverURL: server, type: "video", title: "A+B", uri: "server://M/x"
        ))
        XCTAssertTrue(url.absoluteString.contains("title=A%2BB"))
    }

    func test_move_withoutAfter_hasNoAfterParam() throws {
        let url = try XCTUnwrap(PlexNetworkManager.movePlaylistItemURL(
            serverURL: server, ratingKey: "9", playlistItemID: "82017", after: nil
        ))
        XCTAssertEqual(url.path, "/playlists/9/items/82017/move")
        XCTAssertNil(url.query)
    }

    func test_move_withAfter() throws {
        let url = try XCTUnwrap(PlexNetworkManager.movePlaylistItemURL(
            serverURL: server, ratingKey: "9", playlistItemID: "82017", after: "82015"
        ))
        XCTAssertEqual(url.path, "/playlists/9/items/82017/move")
        XCTAssertEqual(query(url), ["after": "82015"])
    }

    func test_remove_path() throws {
        let url = try XCTUnwrap(PlexNetworkManager.playlistItemURL(
            serverURL: server, ratingKey: "9", playlistItemID: "82017"
        ))
        XCTAssertEqual(url.absoluteString, "\(server)/playlists/9/items/82017")
    }

    func test_rename_query() throws {
        let url = try XCTUnwrap(PlexNetworkManager.renamePlaylistURL(
            serverURL: server, ratingKey: "9", title: "Road Trip"
        ))
        XCTAssertEqual(url.path, "/playlists/9")
        XCTAssertEqual(query(url), ["title": "Road Trip"])
    }

    func test_delete_path() throws {
        let url = try XCTUnwrap(PlexNetworkManager.playlistURL(serverURL: server, ratingKey: "9"))
        XCTAssertEqual(url.absoluteString, "\(server)/playlists/9")
    }

    // Plex `after` is the entry that precedes the moved one once it lands.
    func test_moveAfter_derivesPrecedingEntry() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertNil(PlexProvider.moveAfter(entryID: "c", toIndex: 0, in: ids))
        XCTAssertEqual(PlexProvider.moveAfter(entryID: "a", toIndex: 2, in: ids), "c")
        XCTAssertEqual(PlexProvider.moveAfter(entryID: "d", toIndex: 1, in: ids), "a")
        XCTAssertEqual(PlexProvider.moveAfter(entryID: "b", toIndex: 3, in: ids), "d")
    }
}
