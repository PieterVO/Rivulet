// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlaylistMenus.swift
//  Rivulet
//
//  Video playlist editing from tile menus: Add to Playlist, New Playlist,
//  Rename and Delete. Pure builders for the rows, presenters for the flows.
//

import UIKit

enum PlaylistMenus {
    enum PickerRow: Equatable { case newPlaylist, playlist(MediaPlaylist) }
    enum EntryAction: Equatable { case playFromHere, move, remove }
    enum PlaylistAction: Equatable { case play, shuffle, rename, delete }

    /// New Playlist first, then the regular playlists by title. Smart ones reject additions.
    static func pickerRows(playlists: [MediaPlaylist]) -> [PickerRow] {
        [.newPlaylist] + playlists.filter { !$0.isSmart }
            .sorted { $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending }
            .map { .playlist($0) }
    }

    static func entryActions(isSmart: Bool) -> [EntryAction] {
        isSmart ? [.playFromHere] : [.playFromHere, .move, .remove]
    }

    static func playlistTileActions(isSmart: Bool) -> [PlaylistAction] {
        isSmart ? [.play, .shuffle, .delete] : [.play, .shuffle, .rename, .delete]
    }

    /// The tile kinds a playlist takes, on a server that has playlists. A folder's
    /// video entry is a playable file whatever its kind (a home video maps to `.unknown`).
    @MainActor static func canAdd(_ item: MediaItem, provider: (any MediaProvider)?, isVideoFile: Bool = false) -> Bool {
        (isVideoFile || [.movie, .episode, .season, .show].contains(item.kind)) && !item.ref.itemID.isEmpty
            && provider?.supportsPlaylists == true
    }

    /// Play from Here starts on the picked entry itself: never the list's Continue prompt.
    static func playFromHereQueue(_ entries: [PlaylistEntry], at index: Int) -> PlayQueue<PlaylistEntry>? {
        PlayQueue(entries: entries, startingAt: index)
    }

    // MARK: - Flows

    /// Fetches the item's server's playlists fresh (they change elsewhere) and shows the picker.
    @MainActor static func presentAddToPlaylist(for item: MediaItem, from presenter: UIViewController,
                                                sourceFrame: CGRect? = nil) {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else { return }
        Task { @MainActor in
            let lists: [MediaPlaylist]
            do { lists = try await provider.videoPlaylists() } catch { return reportFailure(error, from: presenter) }
            let actions = pickerRows(playlists: lists).map { row in
                switch row {
                case .newPlaylist:
                    TileMenuAction(title: "New Playlist", systemImage: "plus") {
                        presentNewPlaylist(seededWith: item, provider: provider, from: presenter)
                    }
                case .playlist(let playlist):
                    TileMenuAction(title: playlist.item.title, systemImage: "list.bullet.rectangle") {
                        change(from: presenter) { try await provider.addToPlaylist(playlist.item.ref, items: [item.ref]) }
                    }
                }
            }
            guard let top = MusicPresenter.top(from: presenter), top.presentedViewController == nil else { return }
            top.present(TileMenuPopupViewController(sections: [actions], sourceFrame: sourceFrame), animated: false)
        }
    }

    @MainActor private static func presentNewPlaylist(seededWith item: MediaItem, provider: any MediaProvider,
                                                      from presenter: UIViewController) {
        presentNameEntry(title: "New Playlist", initialText: "", from: presenter) { name in
            change(from: presenter) {
                _ = try await provider.createPlaylist(title: name, seededWith: [item.ref])
            }
        }
    }

    @MainActor static func presentRename(_ playlist: MediaPlaylist, from presenter: UIViewController) {
        guard let provider = MediaProviderRegistry.shared.provider(for: playlist.item.ref.providerID) else { return }
        presentNameEntry(title: "Rename Playlist", initialText: playlist.item.title, from: presenter) { name in
            change(from: presenter) { try await provider.renamePlaylist(playlist.item.ref, title: name) }
        }
    }

    @MainActor static func confirmDelete(_ playlist: MediaPlaylist, from presenter: UIViewController) {
        guard let provider = MediaProviderRegistry.shared.provider(for: playlist.item.ref.providerID) else { return }
        presenter.present(ConfirmationPopupViewController(
            title: "Delete \u{201C}\(playlist.item.title)\u{201D}?",
            message: "This removes the playlist from your server. The titles stay in your library.",
            confirmTitle: "Delete", destructive: true,
            onConfirm: {
                change(from: presenter) { try await provider.deletePlaylist(playlist.item.ref) }
            }), animated: true)
    }

    /// Presents on the next turn, after any closing menu or popup's transition, so the
    /// presentation is not dropped. nil presenter = the key window's top.
    @MainActor static func presentNameEntry(title: String, initialText: String, from presenter: UIViewController?,
                                            onCommit: @escaping (String) -> Void) {
        let entry = TextEntryViewController(title: title, fieldName: "Playlist Name", initialText: initialText,
                                            allowsEmpty: false) { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { onCommit(trimmed) }
        }
        DispatchQueue.main.async {
            guard let top = MusicPresenter.top(from: presenter) else { return }
            if let transition = top.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { _ in
                    MusicPresenter.top(from: presenter)?.present(entry, animated: true)
                }
            } else {
                top.present(entry, animated: true)
            }
        }
    }

    /// Runs a server edit, then repaints every surface. The post's `ServerDataStore.reload()`
    /// also refreshes the sidebar's Playlists rows.
    @MainActor static func change(from presenter: UIViewController,
                                  _ edit: @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await edit()
            } catch {
                return reportFailure(error, from: presenter)
            }
            NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
        }
    }

    @MainActor static func reportFailure(_ error: Error, from presenter: UIViewController) {
        let reason = switch error as? MediaProviderError {
        case .unreachable: "Couldn't reach the server."
        case .unauthorized: "The server didn't accept your sign-in."
        case .notFound: "The server no longer has this playlist."
        case .backendSpecific(let underlying): underlying
        default: error.localizedDescription
        }
        MusicPresenter.top(from: presenter)?.present(
            ConfirmationPopupViewController(title: "Couldn't update the playlist.", message: reason,
                                            confirmTitle: "OK", cancelTitle: nil, onConfirm: {}),
            animated: true)
    }
}
