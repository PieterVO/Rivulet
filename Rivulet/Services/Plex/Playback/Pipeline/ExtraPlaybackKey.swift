// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ExtraPlaybackKey.swift
//  Rivulet
//
//  Issue #255: trailers failed to play "more times than not". Extras come in two
//  flavors and only one is addressable as a library item:
//
//    - User-added (disc rips): carry a real library ratingKey.
//    - Plex IVA (studio-supplied): NO library ratingKey. The only handle Plex
//      gives is `key`, an absolute part path like /services/iva/assets/...
//
//  The play path fed the extra's `id` straight into /library/metadata/{id}. For
//  IVA extras that builds a nonsense URL which 404s, and since IVA extras are the
//  common case on most libraries, most trailers failed. Which flavor an extra is
//  decides how it must be played, so that decision lives here as a pure function.
//
//  Pure: no network, no UIKit.
//

import Foundation

enum ExtraPlaybackKey {

    /// How an extra must be played.
    enum Route: Equatable {
        /// Library-addressable: fetch metadata for this ratingKey, then route normally.
        case libraryMetadata(ratingKey: String)
        /// Already a playable part path; hand it to ContentRouter directly.
        case directPartPath(String)

        /// Stable, low-cardinality label for telemetry.
        var telemetryName: String {
            switch self {
            case .libraryMetadata: return "library_metadata"
            case .directPartPath:  return "direct_part_path"
            }
        }
    }

    static func route(for key: String) -> Route {
        if let ratingKey = libraryRatingKey(from: key) {
            return .libraryMetadata(ratingKey: ratingKey)
        }
        return .directPartPath(key)
    }

    /// Reduce a playback key to a library ratingKey, or nil if it isn't
    /// library-addressable (IVA assets, or anything else off /library/metadata).
    static func libraryRatingKey(from key: String) -> String? {
        if !key.isEmpty, key.allSatisfy(\.isNumber) { return key }
        // "/library/metadata/12345" (possibly with trailing segments) → "12345"
        let parts = key.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, parts[0] == "library", parts[1] == "metadata",
              parts[2].allSatisfy(\.isNumber) else { return nil }
        return parts[2]
    }

    /// Low-cardinality description of a key for telemetry. Never the key itself —
    /// extra paths carry asset identifiers, and the project rule is to send a
    /// category rather than a URL.
    static func keyShape(_ key: String) -> String {
        if key.isEmpty { return "empty" }
        if key.allSatisfy(\.isNumber) { return "numeric_rating_key" }
        if key.hasPrefix("/library/metadata/") { return "library_metadata_path" }
        if key.hasPrefix("/services/iva/") { return "iva_asset_path" }
        if key.hasPrefix("/") { return "other_absolute_path" }
        return "other"
    }
}
