//
//  TopShelfMapper.swift
//  Rivulet
//
//  Pure mapping from Plex Continue Watching metadata to Top Shelf items.
//  Extracted from PlexDataStore.updateTopShelfCache so the movie-inclusion
//  behavior (GitHub #194) is unit-testable without network/auth singletons.
//

import Foundation

enum TopShelfMapper {

    /// Map dedicated `/hubs/continueWatching` metadata into Top Shelf items.
    /// - Dedupes by ratingKey (first wins), sorts by lastViewedAt desc, caps at `limit`.
    /// - Always emits an item when `ratingKey` exists — never drops movies (or any
    ///   item) for missing art. Backdrop is preferred; poster is the fallback the
    ///   extension uses when `wideImageURL` is empty.
    static func items(
        from metadata: [PlexMetadata],
        serverURL: String,
        token: String,
        limit: Int = 5
    ) -> [TopShelfItem] {
        // Dedupe by ratingKey, keep first occurrence.
        var seen = Set<String>()
        var deduped: [PlexMetadata] = []
        for m in metadata {
            guard let key = m.ratingKey, !seen.contains(key) else { continue }
            seen.insert(key)
            deduped.append(m)
        }
        // Most-recent first.
        deduped.sort { ($0.lastViewedAt ?? 0) > ($1.lastViewedAt ?? 0) }

        return deduped.prefix(limit).compactMap { m -> TopShelfItem? in
            guard let ratingKey = m.ratingKey else { return nil }
            let isEpisode = m.type == "episode"

            // Bare episode name for the carousel — the show name rides the line
            // above (contextTitle) Apple-TV+-style, so no "SxxExx - " prefix here
            // (that's what `fullEpisodeTitle` would add).
            let title = m.title ?? "Unknown"
            let subtitle = isEpisode ? m.grandparentTitle : nil

            // Tall poster (kept for fallback) — episode prefers show poster.
            let posterPath = isEpisode
                ? (m.grandparentThumb ?? m.parentThumb ?? m.thumb)
                : m.thumb
            // Wide 16:9 backdrop — episode prefers show backdrop.
            let widePath = isEpisode
                ? (m.grandparentArt ?? m.parentThumb ?? m.thumb)
                : (m.art ?? m.thumb)

            let lastWatched = m.lastViewedAt
                .map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()

            return TopShelfItem(
                ratingKey: ratingKey,
                title: title,
                subtitle: subtitle,
                imageURL: absoluteURL(posterPath, serverURL: serverURL, token: token),
                wideImageURL: absoluteURL(widePath, serverURL: serverURL, token: token),
                logoImageURL: "",
                compositeFileName: nil,
                progress: m.watchProgress ?? 0,
                type: m.type ?? "movie",
                lastWatched: lastWatched,
                serverIdentifier: serverURL
            )
        }
    }

    /// Resolve a Plex image path to an absolute, token-bearing URL string.
    /// Returns "" when the path is nil/empty (extension treats empty as "fall back").
    private static func absoluteURL(_ path: String?, serverURL: String, token: String) -> String {
        guard let path, !path.isEmpty else { return "" }
        var url = path.hasPrefix("http") ? path : "\(serverURL)\(path)"
        if !url.contains("X-Plex-Token") {
            url += url.contains("?") ? "&" : "?"
            url += "X-Plex-Token=\(token)"
        }
        return url
    }
}
