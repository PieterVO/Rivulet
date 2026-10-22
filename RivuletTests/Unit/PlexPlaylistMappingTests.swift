// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexPlaylistMappingTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class PlexPlaylistMappingTests: XCTestCase {
    private let listJSON = #"""
    {"MediaContainer":{"size":2,"Metadata":[
      {"ratingKey":"300","title":"Road Trip","smart":false,"composite":"/playlists/300/composite/1","leafCount":12,"playlistType":"video"},
      {"ratingKey":"301","title":"Unwatched","smart":true,"leafCount":400,"playlistType":"video"}
    ]}}
    """#

    private func playlists() throws -> [MediaPlaylist] {
        let rows = try JSONDecoder().decode(PlexPlaylistContainer.self, from: Data(listJSON.utf8))
            .MediaContainer.Metadata ?? []
        return rows.map { PlexMediaMapper.playlist($0, providerID: "plex:abc", serverURL: "https://x", authToken: "T") }
    }

    func test_playlistMetadata_mapsToPlaylistKind() throws {
        XCTAssertEqual(PlexMediaMapper.kind("playlist"), .playlist)
        let mapped = try playlists()
        XCTAssertEqual(mapped.map(\.item.kind), [.playlist, .playlist])
        XCTAssertEqual(mapped[0].item.ref, MediaItemRef(providerID: "plex:abc", itemID: "300"))
        XCTAssertEqual(mapped[0].item.title, "Road Trip")
        XCTAssertNotNil(mapped[0].item.artwork.poster)
    }

    func test_cardArt_isCompositeAskedFor16x9() throws {
        let mapped = try playlists()
        let card = try XCTUnwrap(mapped[0].item.artwork.backdrop)
        let query = try XCTUnwrap(URLComponents(url: card, resolvingAgainstBaseURL: false)?.queryItems)
        let value = { name in query.first { $0.name == name }?.value }
        XCTAssertEqual(card.path, "/playlists/300/composite/1")
        XCTAssertEqual(value("width"), "1280")
        XCTAssertEqual(value("height"), "720")
        XCTAssertNotNil(value("X-Plex-Token"))
        XCTAssertNil(mapped[1].item.artwork.backdrop, "no composite, no card art")
    }

    func test_playlistItemID_decodes() throws {
        let json = #"""
        {"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
          {"ratingKey":"1001","type":"movie","title":"Heat","playlistItemID":82017}
        ]}}
        """#
        let rows = try JSONDecoder().decode(PlexMediaContainerWrapper.self, from: Data(json.utf8))
            .MediaContainer.Metadata ?? []
        XCTAssertEqual(rows.first?.playlistItemID, 82017)
    }

    func test_smart_decodes_jsonBool() throws {
        XCTAssertEqual(try playlists().map(\.isSmart), [false, true])
    }

    func test_leafCount_isNeverUsedForCount() throws {
        XCTAssertEqual(try playlists().map(\.item.childProgress), [nil, nil])
        var meta = PlexMetadata()
        meta.ratingKey = "300"
        meta.type = "playlist"
        meta.leafCount = 12
        let item = PlexMediaMapper.item(meta, providerID: "plex:abc", serverURL: "https://x", authToken: "T")
        XCTAssertNil(item.childProgress)
    }

    func test_playlistTile_isThreeAcrossSixteenByNineCard() {
        let tile = MediaRowMetrics.playlist
        XCTAssertEqual(MediaRowMetrics.playlistFullCount, 3)
        XCTAssertEqual(tile.art, CGSize(width: 560, height: 315))
        XCTAssertEqual(tile.frame, CGSize(width: 600, height: 355))
        XCTAssertEqual(tile.leading, MediaRowMetrics.rowLeading - 20)
    }
}
