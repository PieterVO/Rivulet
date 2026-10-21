// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// One Codable Home or library row of flat `MediaItem`s, as Home renders it.
// Built by `PlexDataStore.projectHomeItems()` / `projectLibraryItems()` and the Jellyfin store,
// cached by `CacheManager.cacheHomeItems`. `id` is the row's `HomeSectionID.raw`.

import Foundation

nonisolated struct CachedHomeHub: Codable, Sendable {
    var id: String
    var title: String
    var isContinueWatching: Bool
    var hubKey: String?
    var hubIdentifier: String?
    var totalSize: Int?
    var items: [MediaItem]
}

/// An ordered list of home/library hub rows — the full projection for one
/// surface (the home, or a single library page).
typealias CachedHomeRail = [CachedHomeHub]
