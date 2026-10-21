// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexLibraryVisibilityFilter.swift
//  Rivulet
//
//  Restricts a cross-library `[PlexMetadata]` list to the libraries the user shows.
//  Hidden libraries are client-side only, and `/hubs/continueWatching` and `/hubs`
//  span every library, so filtering happens here, while items still carry their
//  section (a `MediaItem` does not).
//

import Foundation

/// Section-attribution predicate shared by every consumer of an account-level
/// (cross-library) Plex hub.
nonisolated enum PlexLibraryVisibilityFilter {

    /// Normalizes a section identifier to its bare numeric form. Plex writes
    /// `librarySectionKey` as `/library/sections/3` and `PlexLibrary.key` as `3`.
    static func normalizedSectionID(_ raw: String) -> String {
        guard let slash = raw.lastIndex(of: "/") else { return raw }
        return String(raw[raw.index(after: slash)...])
    }

    /// Builds the comparison set from library keys.
    static func normalizedKeySet(_ libraryKeys: some Sequence<String>) -> Set<String> {
        Set(libraryKeys.map(normalizedSectionID))
    }

    /// Whether `item` belongs to one of `normalizedKeys`. Fails open on an empty
    /// key set (libraries not loaded yet on a cold launch) and on an item with no
    /// section fields, so neither blanks Continue Watching.
    static func isVisible(_ item: PlexMetadata, in normalizedKeys: Set<String>) -> Bool {
        guard !normalizedKeys.isEmpty else { return true }
        if let sectionKey = item.librarySectionKey {
            return normalizedKeys.contains(normalizedSectionID(sectionKey))
        }
        if let sectionID = item.librarySectionID {
            return normalizedKeys.contains(String(sectionID))
        }
        return true
    }

    /// Filters a cross-library metadata list down to `libraryKeys`.
    static func filter(_ items: [PlexMetadata], toLibraryKeys libraryKeys: some Sequence<String>) -> [PlexMetadata] {
        let keys = normalizedKeySet(libraryKeys)
        guard !keys.isEmpty else { return items }
        return items.filter { isVisible($0, in: keys) }
    }
}
