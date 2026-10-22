// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlaylistEntry.swift
//  Rivulet
//
//  A video playlist and its rows, across backends.
//

import Foundation

/// One row of a playlist. `entryID` names the row, not the title, so the same
/// title twice is two entries (Plex `playlistItemID`, Jellyfin `PlaylistItemId`).
struct PlaylistEntry: Hashable, Sendable {
    let entryID: String
    let item: MediaItem
}

struct MediaPlaylist: Hashable, Sendable {
    let item: MediaItem
    let isSmart: Bool

    /// Pixel size of the 16:9 card art (`artwork.backdrop`) on the playlists grid.
    static let cardSize = (width: 1280, height: 720)
}
