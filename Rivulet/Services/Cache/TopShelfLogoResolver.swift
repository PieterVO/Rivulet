// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TopShelfLogoResolver.swift
//  Rivulet
//
//  Pure helpers for resolving a Plex clearLogo URL for Top Shelf items.
//  Mirrors ContinueWatchingCell.resolveLogoURL: episodes resolve via the
//  grandparent (show) metadata, movies via their own.
//

import Foundation

enum TopShelfLogoResolver {

    /// The ratingKey whose full metadata carries the clearLogo:
    /// episodes → the show (grandparent); everything else → itself.
    static func sourceRatingKey(for item: PlexMetadata) -> String? {
        if item.type == "episode" {
            return item.grandparentRatingKey
        }
        return item.ratingKey
    }

    /// Absolute, token-bearing clearLogo URL string from already-fetched full
    /// metadata, or "" when the metadata has no clearLogo.
    static func logoURLString(from fullMetadata: PlexMetadata, serverURL: String, token: String) -> String {
        guard let path = fullMetadata.clearLogoPath, !path.isEmpty else { return "" }
        let isAbsolute = path.hasPrefix("http")
        var url = isAbsolute ? path : "\(serverURL)\(path)"
        // An absolute URL on another host (a metadata CDN) must not receive the token.
        if !url.contains("X-Plex-Token"), !isAbsolute || URL(string: path)?.host == URL(string: serverURL)?.host {
            url += url.contains("?") ? "&" : "?"
            url += "X-Plex-Token=\(token)"
        }
        return url
    }
}
