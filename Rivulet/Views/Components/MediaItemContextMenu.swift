//
//  MediaItemContextMenu.swift
//  Rivulet
//
//  SwiftUI long-press context menu for the episode cards/rows inside
//  MediaDetailView — its ONLY remaining surface. Every other long-press
//  menu (home rows, library grid) is the UIKit tile menu built in
//  PlexHomeViewController.tileMenuSections + TileMenuPopupViewController,
//  which is the canonical menu; keep the two in step from that side.
//

import SwiftUI

// MARK: - Context Menu Actions

/// Callback type for context menu actions that may require data refresh
typealias MediaItemRefreshCallback = () async -> Void

/// Callback type for navigation actions (synchronous)
typealias MediaItemNavigationCallback = () -> Void

// MARK: - Context Menu Modifier

/// A view modifier that adds a context menu to media items with common Plex actions
struct MediaItemContextMenu: ViewModifier {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String
    var onRefreshNeeded: MediaItemRefreshCallback?
    var onShowInfo: MediaItemNavigationCallback?

    @State private var isPerformingAction = false

    private let networkManager = PlexNetworkManager.shared
    private let dataStore = PlexDataStore.shared

    func body(content: Content) -> some View {
        content.contextMenu {
            // Watch from Beginning
            Button {
                performAction(optimisticWatched: false) {
                    try await networkManager.markUnwatched(
                        serverURL: serverURL,
                        authToken: authToken,
                        ratingKey: item.ratingKey ?? ""
                    )
                }
            } label: {
                Label("Watch from Beginning", systemImage: "play.fill")
            }

            Divider()

            // Mark as Watched
            if item.viewCount == nil || item.viewCount == 0 || item.watchProgress != nil {
                Button {
                    performAction(optimisticWatched: true) {
                        try await networkManager.markWatched(
                            serverURL: serverURL,
                            authToken: authToken,
                            ratingKey: item.ratingKey ?? ""
                        )
                    }
                } label: {
                    Label("Mark as Watched", systemImage: "eye.fill")
                }
            }

            // Mark as Unwatched (only show if already watched)
            if let viewCount = item.viewCount, viewCount > 0 {
                Button {
                    performAction(optimisticWatched: false) {
                        try await networkManager.markUnwatched(
                            serverURL: serverURL,
                            authToken: authToken,
                            ratingKey: item.ratingKey ?? ""
                        )
                    }
                } label: {
                    Label("Mark as Unwatched", systemImage: "eye.slash.fill")
                }
            }

            Divider()

            // More Info (navigate to detail view)
            if let onShowInfo = onShowInfo {
                Button {
                    onShowInfo()
                } label: {
                    Label("More Info", systemImage: "info.circle")
                }
            }

            // Refresh Metadata
            Button {
                performAction {
                    try await networkManager.refreshMetadata(
                        serverURL: serverURL,
                        authToken: authToken,
                        ratingKey: item.ratingKey ?? ""
                    )
                }
            } label: {
                Label("Refresh Metadata", systemImage: "arrow.clockwise")
            }
        }
    }

    private func performAction(optimisticWatched: Bool? = nil, _ action: @escaping () async throws -> Void) {
        guard !isPerformingAction else { return }
        isPerformingAction = true

        Task {
            do {
                try await action()
                // Apply optimistic update immediately for instant UI feedback
                if let watched = optimisticWatched, let ratingKey = item.ratingKey {
                    await MainActor.run {
                        dataStore.updateItemWatchStatus(ratingKey: ratingKey, watched: watched)
                    }
                }
                // Also refresh from server for consistency
                await onRefreshNeeded?()
            } catch {
                print("Context menu action failed: \(error)")
            }
            isPerformingAction = false
        }
    }
}

// MARK: - View Extension

extension View {
    /// Adds a context menu with common Plex media actions. Adapts the agnostic
    /// MediaItem to the Plex-typed modifier by resolving the ratingKey from the
    /// item's ref and deriving watch state from MediaUserState.
    func mediaItemContextMenu(
        mediaItem: MediaItem,
        serverURL: String,
        authToken: String,
        onRefreshNeeded: MediaItemRefreshCallback? = nil,
        onShowInfo: MediaItemNavigationCallback? = nil
    ) -> some View {
        // Build a minimal PlexMetadata shell so the modifier can reuse its
        // Plex network calls.
        var shell = PlexMetadata()
        shell.ratingKey = mediaItem.ref.itemID
        shell.type = mediaItem.kind == .episode ? "episode"
                   : mediaItem.kind == .show ? "show"
                   : mediaItem.kind == .season ? "season"
                   : "movie"
        shell.viewCount = mediaItem.userState.isPlayed ? 1 : (mediaItem.isInProgress ? 0 : nil)
        shell.viewOffset = mediaItem.userState.viewOffset > 0 ? Int(mediaItem.userState.viewOffset * 1000) : nil
        shell.parentRatingKey = mediaItem.parentRef?.itemID
        shell.grandparentRatingKey = mediaItem.grandparentRef?.itemID
        return modifier(MediaItemContextMenu(
            item: shell,
            serverURL: serverURL,
            authToken: authToken,
            onRefreshNeeded: onRefreshNeeded,
            onShowInfo: onShowInfo
        ))
    }
}
