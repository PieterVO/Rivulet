// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class PlaylistMenusTests: XCTestCase {

    private func playlist(_ title: String, smart: Bool = false) -> MediaPlaylist {
        let item = MediaItem(
            ref: MediaItemRef(providerID: "plex:a", itemID: title), kind: .playlist, title: title,
            sortTitle: nil, overview: nil, year: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil)
        return MediaPlaylist(item: item, isSmart: smart)
    }

    func test_picker_newPlaylistFirst() {
        let rows = PlaylistMenus.pickerRows(playlists: [playlist("B"), playlist("A")])
        XCTAssertEqual(rows.first, .newPlaylist)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(PlaylistMenus.pickerRows(playlists: []), [.newPlaylist])
    }

    func test_picker_excludesSmart() {
        let rows = PlaylistMenus.pickerRows(playlists: [playlist("Rules", smart: true), playlist("Mine")])
        XCTAssertEqual(rows, [.newPlaylist, .playlist(playlist("Mine"))])
    }

    func test_picker_sortedByTitle() {
        let rows = PlaylistMenus.pickerRows(playlists: [playlist("zebra"), playlist("Apple"), playlist("mango")])
        XCTAssertEqual(rows, [.newPlaylist, .playlist(playlist("Apple")), .playlist(playlist("mango")),
                              .playlist(playlist("zebra"))])
    }

    func test_entryActions_smartIsPlayOnly() {
        XCTAssertEqual(PlaylistMenus.entryActions(isSmart: true), [.playFromHere])
        XCTAssertEqual(PlaylistMenus.entryActions(isSmart: false), [.playFromHere, .move, .remove])
    }

    /// Play from Here on the first tile starts there, even with a continue point further down.
    func test_playFromHere_firstEntry_ignoresContinuePoint() {
        let entries = ["A", "B", "A"].enumerated().map { index, title in
            PlaylistEntry(entryID: "e\(index)", item: playlist(title).item)
        }
        XCTAssertEqual(PlaylistMenus.playFromHereQueue(entries, at: 0)?.index, 0)
        XCTAssertEqual(PlaylistMenus.playFromHereQueue(entries, at: 2)?.current.entryID, "e2")
    }

    func test_playlistTileActions_smartHasNoRename() {
        XCTAssertEqual(PlaylistMenus.playlistTileActions(isSmart: true), [.play, .shuffle, .delete])
        XCTAssertEqual(PlaylistMenus.playlistTileActions(isSmart: false), [.play, .shuffle, .rename, .delete])
    }
}
