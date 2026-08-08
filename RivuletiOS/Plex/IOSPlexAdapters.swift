// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

//
//  Presentation conveniences the iOS views read off the shared Plex models.
//
//  These replace IOSPlexItem / IOSPlexLibrary, which were a second set of
//  decoders for the same endpoints. The decoding now happens once, in
//  RivuletCore's PlexMetadata, and only the display-shaped accessors live
//  here — iOS-only because they encode iOS presentation choices (SF Symbol
//  names, a one-line subtitle) that tvOS renders differently.
//
//  Nothing here may reimplement a rule. Resume progress goes through
//  WatchProgressPolicy, not a second threshold.
//

extension PlexMetadata {
    var displayTitle: String { title ?? "Untitled" }

    /// One-line supporting text: episode coordinates and show for an episode,
    /// year for everything else.
    var subtitle: String? {
        if type == "episode" {
            let code = [parentIndex, index].compactMap { $0 }.map(String.init)
            let prefix = code.count == 2 ? "S\(code[0]) E\(code[1])" : nil
            return [prefix, grandparentTitle].compactMap { $0 }.joined(separator: " · ")
        }
        return year.map(String.init)
    }

    var isPlayable: Bool { type == "movie" || type == "episode" || type == "clip" }

    /// Music tiles are 1:1, not 2:3 — album and artist art is square.
    var isMusic: Bool { ["artist", "album", "track"].contains(type ?? "") }

    var durationSeconds: TimeInterval { TimeInterval(duration ?? 0) / 1000 }
    var resumeSeconds: TimeInterval { TimeInterval(viewOffset ?? 0) / 1000 }

    /// Artwork for a poster tile, matching tvOS `PosterCell`
    /// (`grandparentArtwork?.poster ?? artwork.poster`).
    ///
    /// The grandparent wins because an episode's own `thumb` is a 16:9 still,
    /// not a poster, and Recently Added for a TV library returns episodes. A
    /// season has no grandparent, so it keeps its own poster.
    var posterPath: String? { grandparentThumb ?? thumb ?? parentThumb }
}

extension PlexLibrary {
    /// SF Symbol for the library's content type. iOS-only: the tvOS sidebar
    /// draws libraries with its own artwork.
    var icon: String {
        switch type {
        case "movie": "film.stack"
        case "show": "tv"
        case "artist": "music.note.list"
        default: "rectangle.stack"
        }
    }
}

extension PlexHub {
    /// Hubs always render with a heading on iOS, so collapse the optional here
    /// rather than at each call site.
    var displayTitle: String { title ?? "" }

    var items: [PlexMetadata] { Metadata ?? [] }

    var isContinueWatching: Bool {
        (title ?? "").localizedCaseInsensitiveContains("continue watching")
    }

    var isOnDeck: Bool {
        (title ?? "").localizedCaseInsensitiveContains("on deck")
    }
}
