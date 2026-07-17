// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TopShelfComposer.swift
//  Rivulet
//
//  Builds Apple TV+-style Top Shelf images in-app: resolves each item's
//  clearLogo, downloads backdrop + logo, composites them, and writes the
//  result to the App Group container. The extension only reads the files.
//  Never throws; any per-item failure falls back to the plain backdrop.
//

import UIKit

enum TopShelfComposer {

    /// Returns items with `logoImageURL` / `compositeFileName` populated where a
    /// composite was produced. Prunes composite files to the current set.
    @MainActor
    static func composite(items: [TopShelfItem], serverURL: String, token: String) async -> [TopShelfItem] {
        var result: [TopShelfItem] = []
        var keptFiles: Set<String> = []

        for item in items {
            var logoURLString = ""
            var compositeFileName: String? = nil

            // 1. Resolve clearLogo URL (via full/grandparent metadata, cached).
            //    fullMetadata() handles episode → grandparent (show) resolution.
            if let full = await fullMetadata(for: item.ratingKey, serverURL: serverURL, token: token) {
                logoURLString = TopShelfLogoResolver.logoURLString(from: full, serverURL: serverURL, token: token)
            }

            // 2. Compose only when we have both a backdrop and a logo.
            let backdropURLString = item.wideImageURL.isEmpty ? item.imageURL : item.wideImageURL
            if !logoURLString.isEmpty,
               let backdropURL = URL(string: backdropURLString),
               let logoURL = URL(string: logoURLString),
               let backdrop = await ImageCacheManager.shared.image(for: backdropURL, quality: .full),
               let logo = await ImageCacheManager.shared.image(for: logoURL, quality: .full) {

                let composed = TopShelfImageCompositor.compose(backdrop: backdrop, logo: logo)
                if let data = composed.jpegData(compressionQuality: 0.9) {
                    let fileName = "\(item.ratingKey).jpg"
                    if TopShelfCache.shared.writeComposite(data, fileName: fileName) {
                        compositeFileName = fileName
                        keptFiles.insert(fileName)
                    }
                }
            }

            result.append(TopShelfItem(
                ratingKey: item.ratingKey,
                title: item.title,
                subtitle: item.subtitle,
                imageURL: item.imageURL,
                wideImageURL: item.wideImageURL,
                logoImageURL: logoURLString,
                compositeFileName: compositeFileName,
                progress: item.progress,
                type: item.type,
                lastWatched: item.lastWatched,
                serverIdentifier: item.serverIdentifier
            ))
        }

        // 3. Prune any composite files not in the current set.
        TopShelfCache.shared.pruneComposites(keeping: keptFiles)
        return result
    }

    // MARK: - Helpers

    /// Full metadata carrying the clearLogo. `TopShelfItem` doesn't carry
    /// `grandparentRatingKey`, so for episodes we fetch the item's own metadata
    /// first (which carries the grandparent key), then resolve the grandparent
    /// (show) metadata where the show logo lives.
    private static func fullMetadata(for ratingKey: String, serverURL: String, token: String) async -> PlexMetadata? {
        if let cached = PlexDataStore.shared.getCachedFullMetadata(for: ratingKey) {
            // For episodes, the show logo lives on the grandparent — resolve that.
            if cached.type == "episode", let gp = cached.grandparentRatingKey {
                return await fetchAndCache(gp, serverURL: serverURL, token: token) ?? cached
            }
            return cached
        }
        guard let fetched = await fetchAndCache(ratingKey, serverURL: serverURL, token: token) else { return nil }
        if fetched.type == "episode", let gp = fetched.grandparentRatingKey {
            return await fetchAndCache(gp, serverURL: serverURL, token: token) ?? fetched
        }
        return fetched
    }

    private static func fetchAndCache(_ ratingKey: String, serverURL: String, token: String) async -> PlexMetadata? {
        if let cached = PlexDataStore.shared.getCachedFullMetadata(for: ratingKey) { return cached }
        do {
            let m = try await PlexNetworkManager.shared.getFullMetadata(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
            PlexDataStore.shared.cacheFullMetadata(m, for: ratingKey)
            return m
        } catch {
            return nil
        }
    }
}
