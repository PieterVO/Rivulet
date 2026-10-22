// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TopShelfFeed.swift
//  Rivulet
//
//  The Top Shelf row: every server's Continue Watching in one list,
//  most recently watched first. Both stores call `refresh` when their row changes.
//

import Foundation

@MainActor
enum TopShelfFeed {
    static let limit = 5

    static func refresh() async {
        let auth = PlexAuthManager.shared
        let profiles = PlexUserProfileManager.shared
        // The Home screen row sits outside the PIN gate (a remembered PIN reopens it unasked).
        guard !auth.relocksOnLaunch || profiles.selectedUser.map(profiles.hasRememberedPin(for:)) ?? false else {
            TopShelfCache.shared.clear()
            return
        }
        // Until a Home profile is entered there is no Plex row to show; keep the last one.
        guard !auth.isContentWithheld else { return }
        let serverURL = auth.selectedServerURL
        let token = auth.selectedServerToken
        var plex: [TopShelfItem] = []
        if let serverURL, let token {
            // /hubs/continueWatching, as the in-app row uses. The global /hubs drops movies (#194).
            plex = TopShelfMapper.items(from: PlexDataStore.shared.continueWatchingHub?.Metadata ?? [],
                                        serverURL: serverURL, token: token, limit: limit * 2)
        }
        let serverStore = ServerDataStore.shared
        let sources = serverStore.sources
        let otherRows = serverStore.homeRows.filter(\.isContinueWatching).map(\.items)
        var others = otherRows.flatMap { TopShelfMapper.items(from: $0, limit: limit * 2) }
        // The same title on two servers is one card, as in Home's merged row.
        if !otherRows.isEmpty, let primaryID = MediaProviderRegistry.shared.plexProvider?.id {
            let primaryRow = PlexDataStore.shared.homeItems.first(where: \.isContinueWatching)?.items ?? []
            let shown = Set(ContinueWatchingRow.shared.cards([primaryRow] + otherRows, identity: { $0.identity ?? [] },
                                                             showKey: \.showKey, watched: \.userState.lastViewedAt)
                                .map(\.item.ref))
            plex.removeAll { !shown.contains(MediaItemRef(providerID: primaryID, itemID: $0.ratingKey)) }
            others.removeAll { !shown.contains(MediaItemRef(providerID: $0.serverIdentifier, itemID: $0.ratingKey)) }
        }

        let items = await TopShelfComposer.composite(
            items: TopShelfMapper.merge(plex, others, limit: limit), serverURL: serverURL, token: token)
        // A profile changed, locked or signed out during the composite.
        guard auth.selectedServerToken == token, serverStore.sources == sources else { return }
        TopShelfCache.shared.writeItems(items)
    }
}
