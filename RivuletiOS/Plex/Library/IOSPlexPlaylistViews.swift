// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// One server's video playlists.
struct IOSPlexPlaylistsRoute: Hashable {
    let serverID: String?
}

struct IOSPlexPlaylistRoute: Hashable {
    let playlist: PlexPlaylist
    let serverID: String?
}

struct IOSPlexPlaylistsView: View {
    let serverID: String?
    var showsAccount = false
    @EnvironmentObject private var plex: IOSPlexSession

    var body: some View {
        let lists = plex.playlists(serverID: serverID)
        Group {
            if lists.isEmpty {
                ContentUnavailableView("No Playlists", systemImage: "list.and.film")
            } else {
                List(lists, id: \.ratingKey) { playlist in
                    NavigationLink(value: IOSPlexPlaylistRoute(playlist: playlist, serverID: serverID)) {
                        IOSPlexPlaylistRow(playlist: playlist, serverID: serverID)
                    }
                }
                .listStyle(.plain)
            }
        }
        .refreshable { await plex.refresh() }
        .navigationTitle(plex.displayTitle("Playlists", serverID: serverID))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if showsAccount { IOSAccountToolbarItem() }
        }
    }
}

private struct IOSPlexPlaylistRow: View {
    let playlist: PlexPlaylist
    let serverID: String?
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .body) private var artWidth: CGFloat = 120

    var body: some View {
        HStack(spacing: 12) {
            IOSPlexImage(url: plex.imageURL(path: playlist.composite, width: Int(artWidth * displayScale),
                                            height: Int(artWidth * displayScale * 9 / 16), serverID: serverID))
                .frame(width: artWidth, height: artWidth * 9 / 16)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title ?? "Untitled").font(.headline).lineLimit(2)
                if let info = playlist.info {
                    Text(info).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private extension PlexPlaylist {
    /// "12 items · 3 hr 10 min"
    var info: String? {
        let count = leafCount.map { "\($0) \($0 == 1 ? "item" : "items")" }
        let length = duration.flatMap { ms in
            Duration.seconds(ms / 1000).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        }
        let parts = [count, length].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A playlist's rows with Play and Shuffle. Read only; edit on the Apple TV or in Plex.
struct IOSPlexPlaylistView: View {
    let route: IOSPlexPlaylistRoute
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.plexActions) private var actions
    @State private var items: [PlexMetadata] = []
    @State private var error: String?
    @State private var loadedRevision: Int?
    @State private var offersContinue = false

    var body: some View {
        Group {
            if items.isEmpty, let error {
                IOSPlexErrorView(title: "Couldn't Load Playlist", message: error) { await reload() }
            } else if items.isEmpty, loadedRevision != nil {
                ContentUnavailableView("Empty Playlist", systemImage: "list.and.film")
            } else if items.isEmpty {
                ProgressView()
            } else {
                List {
                    Section {
                        HStack(spacing: 12) {
                            Button { play() } label: {
                                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            Button { start(.shuffled(items)) } label: {
                                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.large)
                        .listRowSeparator(.hidden)
                    }
                    Section {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            IOSPlexPlaylistItemRow(item: item) { start(PlayQueue(entries: items, startingAt: index)) }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .refreshable { await reload() }
        .navigationTitle(route.playlist.title ?? "Playlist")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(route.playlist.title ?? "Playlist", isPresented: $offersContinue, titleVisibility: .visible) {
            if let resume = continuePoint {
                Button("Continue with \u{201C}\(items[resume].displayTitle)\u{201D}") {
                    start(PlayQueue(entries: items, startingAt: resume))
                }
            }
            Button("Play from Beginning") { start(PlayQueue(entries: items, startingAt: 0)) }
        }
        .task(id: plex.watchStateRevision) {
            guard loadedRevision != plex.watchStateRevision else { return }
            await reload()
        }
    }

    private var continuePoint: Int? {
        PlayQueue.continuePoint(in: items, isPlayed: \.isWatched, isStarted: \.isInProgress)
    }

    /// From the top, offering the list's continue point first, as tvOS does.
    private func play() {
        if let resume = continuePoint, resume > 0 {
            offersContinue = true
        } else {
            start(PlayQueue(entries: items, startingAt: 0))
        }
    }

    private func start(_ queue: PlayQueue<PlexMetadata>?) {
        if let queue { actions.playQueue(queue) }
    }

    private func reload() async {
        let revision = plex.watchStateRevision
        do {
            items = try await plex.playlistItems(route.playlist, serverID: route.serverID)
            error = nil
            loadedRevision = revision
        } catch let error where isCancellationError(error) {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Tapping plays from this row on; the menu has Details.
private struct IOSPlexPlaylistItemRow: View {
    let item: PlexMetadata
    let playFromHere: () -> Void
    private let watchStamp: [Int]
    @Environment(\.plexActions) private var actions
    @ScaledMetric(relativeTo: .body) private var artWidth: CGFloat = 120

    init(item: PlexMetadata, playFromHere: @escaping () -> Void) {
        self.item = item
        self.playFromHere = playFromHere
        watchStamp = item.watchStamp
    }

    var body: some View {
        Button(action: playFromHere) {
            HStack(spacing: 12) {
                IOSPlexArtwork(item: item, kind: item.type == "episode" ? .thumb : .backdrop,
                               width: artWidth, aspectRatio: 16 / 9)
                    .frame(width: artWidth, height: artWidth * 9 / 16)
                    .plexWatchState(item)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        if actions.preparingID == item.id { ProgressView().tint(.white) }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle).font(.headline).lineLimit(2)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let detail = item.timeLeftText ?? item.runtimeText {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .plexContextMenu(item, showsDetails: true)
        .accessibilityHint("Plays the playlist from here")
    }
}
