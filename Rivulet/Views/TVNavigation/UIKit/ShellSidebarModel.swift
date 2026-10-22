// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ShellSidebarModel.swift
//  Rivulet
//

import Foundation

/// One row of the custom shell sidebar.
struct ShellSidebarItem: Hashable {
    let tab: SidebarTab
    let title: String
    /// SF Symbol name.
    let icon: String
    /// The profile row's picture; the symbol stays where there is none.
    var avatarURL: URL?
    /// The profile row only: Select opens the profile switcher.
    var canSwitchProfile = false
    /// The library's server, named on the row once libraries from several
    /// servers are mixed together and no section header can name it.
    var badge: String?
}

/// A server whose sidebar gets a Playlists row.
struct PlaylistServer: Hashable {
    let providerID: String
    let name: String
    /// `LibrarySettingsManager.serverID(ofKey:)` of this server's libraries: "" for the selected Plex server.
    let serverID: String

    /// The servers among `providerIDs`, the selected Plex server first.
    @MainActor static func current(_ providerIDs: Set<String>) -> [PlaylistServer] {
        let plexID = MediaProviderRegistry.shared.plexProvider?.id
        var servers: [PlaylistServer] = []
        if let plexID, providerIDs.contains(plexID) {
            servers.append(PlaylistServer(providerID: plexID,
                                          name: PlexAuthManager.shared.savedServerName ?? "Library", serverID: ""))
        }
        for source in ServerDataStore.shared.sources
        where source.providerID != plexID && providerIDs.contains(source.providerID)
            && !servers.contains(where: { $0.providerID == source.providerID }) {
            servers.append(PlaylistServer(providerID: source.providerID, name: source.name, serverID: source.providerID))
        }
        return servers
    }
}

/// One library in the sidebar, any server's, in the user's order.
struct SidebarLibrary: Hashable {
    /// `LibrarySettingsManager`'s key, which names the server.
    let key: String
    let serverName: String
    let item: ShellSidebarItem

    init(plex library: PlexLibrary, serverName: String) {
        key = library.key
        self.serverName = serverName
        item = ShellSidebarItem(tab: .library(key: library.key), title: library.title,
                                icon: ShellSidebarModel.icon(forLibraryType: library.type))
    }

    init(_ library: MediaLibrary, serverName: String) {
        key = library.settingsKey
        self.serverName = serverName
        item = ShellSidebarItem(tab: .providerLibrary(providerID: library.providerID, libraryID: library.id),
                                title: library.title, icon: ShellSidebarModel.icon(forLibraryKind: library.kind))
    }
    /// Every server's visible libraries in the user's order across servers.
    @MainActor static func current() -> [SidebarLibrary] {
        let plexName = PlexAuthManager.shared.savedServerName ?? "Library"
        let store = ServerDataStore.shared
        let names = Dictionary(store.sources.map { ($0.providerID, $0.name) }, uniquingKeysWith: { first, _ in first })
        let all = PlexDataStore.shared.visibleSidebarLibraries.map { SidebarLibrary(plex: $0, serverName: plexName) }
            + store.visibleLibraries.map { SidebarLibrary($0, serverName: names[$0.providerID] ?? "") }
        return LibrarySettingsManager.shared.arrange(all, key: \.key)
    }
}

/// A group of rows. `title` renders as a small section header; nil means the
/// rows sit flush with no header (the top group, Discover-below, Settings).
struct ShellSidebarSection: Hashable {
    let title: String?
    let items: [ShellSidebarItem]
}

/// Builds the sidebar's section list from live app state. Pure, so the order
/// rules carried over from the system-sidebar shell (Discover position,
/// Live TV combined/separate and position, server-named library section,
/// Settings always last) stay unit-testable.
enum ShellSidebarModel {

    // swiftlint:disable:next function_parameter_count
    static func sections(
        libraries: [SidebarLibrary],
        liveTVSources: [LiveTVDataStore.LiveTVSourceInfo],
        combineLiveTV: Bool,
        showDiscover: Bool,
        discoverAbove: Bool,
        showWatchlist: Bool,
        liveTVAbove: Bool,
        profileName: String,
        profileAvatar: URL? = nil,
        canSwitchProfile: Bool = false,
        hasMediaServer: Bool = true,
        playlistServers: [PlaylistServer] = []
    ) -> [ShellSidebarSection] {
        var sections: [ShellSidebarSection] = []

        // The profile is a header in a section of its own, above the tabs.
        sections.append(ShellSidebarSection(title: nil, items: [
            ShellSidebarItem(tab: .account, title: firstName(of: profileName),
                             icon: "person.crop.circle.fill", avatarURL: profileAvatar,
                             canSwitchProfile: canSwitchProfile),
        ]))

        // Search, Discover and the watchlist need a media server. Without one,
        // Home is only the welcome screen, kept while there is no Live TV instead.
        let showDiscover = showDiscover && hasMediaServer
        var top: [ShellSidebarItem] = []
        if hasMediaServer {
            top.append(ShellSidebarItem(tab: .search, title: "Search", icon: "magnifyingglass"))
        }
        if !opensToLiveTV(hasMediaServer: hasMediaServer, liveTVSources: liveTVSources) {
            top.append(ShellSidebarItem(tab: .home, title: "Home", icon: "house.fill"))
        }
        let discover = ShellSidebarItem(tab: .discover, title: "Discover", icon: "sparkles")
        if showDiscover && discoverAbove {
            top.append(discover)
        }
        // The watchlist is account-level, not a library, so it sits with the
        // other whole-app destinations rather than in the server section.
        if showWatchlist && hasMediaServer {
            top.append(ShellSidebarItem(tab: .watchlist, title: "Watchlist", icon: "bookmark.fill"))
        }
        if !top.isEmpty {
            sections.append(ShellSidebarSection(title: nil, items: top))
        }

        let liveTVSection = ShellSidebarSection(
            title: "Live TV",
            items: liveTVItems(sources: liveTVSources, combined: combineLiveTV))
        let librarySections = self.librarySections(libraries, playlistServers: playlistServers)
        let middle = liveTVAbove ? [liveTVSection] + librarySections : librarySections + [liveTVSection]
        sections.append(contentsOf: middle.filter { !$0.items.isEmpty })

        if showDiscover && !discoverAbove {
            sections.append(ShellSidebarSection(title: nil, items: [discover]))
        }
        sections.append(ShellSidebarSection(
            title: nil,
            items: [ShellSidebarItem(tab: .settings, title: "Settings", icon: "gearshape.fill")]))
        return sections
    }

    /// The libraries, already in the user's order. While each server's sit
    /// together they get a section under the server's name, the selected Plex
    /// server's first by default. Once the user mixes them, one Libraries
    /// section, each row badged with its server. A server with video playlists
    /// gets a Playlists row after its libraries, and a section of its own when
    /// all its libraries are hidden.
    static func librarySections(_ libraries: [SidebarLibrary],
                                playlistServers: [PlaylistServer] = []) -> [ShellSidebarSection] {
        guard LibrarySettingsManager.isGroupedByServer(libraries.map(\.key)) else {
            let items = libraries.map { library in
                var item = library.item
                item.badge = library.serverName
                return item
            } + playlistServers.map { server in
                var item = playlistsItem(server)
                item.badge = server.name
                return item
            }
            return [ShellSidebarSection(title: "Libraries", items: items)]
        }
        var sections: [ShellSidebarSection] = []
        var placed: Set<String> = []
        func close(_ run: [SidebarLibrary]) {
            guard let first = run.first else { return }
            var items = run.map(\.item)
            let serverID = LibrarySettingsManager.serverID(ofKey: first.key)
            if let server = playlistServers.first(where: { $0.serverID == serverID }) {
                items.append(playlistsItem(server))
                placed.insert(server.providerID)
            }
            sections.append(ShellSidebarSection(title: first.serverName, items: items))
        }
        var run: [SidebarLibrary] = []
        for library in libraries {
            if let first = run.first,
               LibrarySettingsManager.serverID(ofKey: first.key) != LibrarySettingsManager.serverID(ofKey: library.key) {
                close(run)
                run = []
            }
            run.append(library)
        }
        close(run)
        for server in playlistServers where !placed.contains(server.providerID) {
            sections.append(ShellSidebarSection(title: server.name, items: [playlistsItem(server)]))
        }
        return sections
    }

    private static func playlistsItem(_ server: PlaylistServer) -> ShellSidebarItem {
        ShellSidebarItem(tab: .playlists(providerID: server.providerID), title: "Playlists",
                         icon: "list.bullet.rectangle")
    }

    /// Live TV with no media server: the app opens on Live TV and Home is hidden.
    static func opensToLiveTV(hasMediaServer: Bool, liveTVSources: [LiveTVDataStore.LiveTVSourceInfo]) -> Bool {
        !hasMediaServer && !liveTVSources.isEmpty
    }

    /// A held or long Up stops at Home and at Search: leaving either upward takes
    /// a fresh press or swipe, so the rarely used profile row is never overshot into.
    static func stopsUpwardRun(from: SidebarTab?, to: SidebarTab?, headingUp: Bool,
                               gestureAlreadyMoved: Bool) -> Bool {
        headingUp && gestureAlreadyMoved && from != to && (from == .home || from == .search)
    }

    /// The first word of a display name; a one-word name or handle is whole.
    static func firstName(of displayName: String) -> String {
        displayName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? displayName
    }

    static func icon(forLibraryType type: String) -> String {
        switch type {
        case "movie": return "film.fill"
        case "show": return "tv.fill"
        case "artist": return "music.note"
        case "photo": return "photo.fill"
        default: return "folder.fill"
        }
    }

    static func icon(forLibraryKind kind: MediaLibrary.LibraryKind) -> String {
        switch kind {
        case .movies: return "film.fill"
        case .shows: return "tv.fill"
        case .music: return "music.note"
        case .photos: return "photo.fill"
        case .mixed, .liveTV: return "folder.fill"
        }
    }

    private static func liveTVItems(
        sources: [LiveTVDataStore.LiveTVSourceInfo],
        combined: Bool
    ) -> [ShellSidebarItem] {
        guard !sources.isEmpty else { return [] }
        if combined {
            return [ShellSidebarItem(tab: .liveTV(sourceId: nil),
                                     title: "Channels",
                                     icon: "play.rectangle.fill")]
        }
        return sources.map { source in
            ShellSidebarItem(tab: .liveTV(sourceId: source.id),
                             title: source.displayName.replacingOccurrences(of: " Live TV", with: ""),
                             icon: icon(forSource: source))
        }
    }

    private static func icon(forSource source: LiveTVDataStore.LiveTVSourceInfo) -> String {
        switch source.sourceType {
        case .plex: return "play.rectangle.fill"
        case .dispatcharr: return "antenna.radiowaves.left.and.right"
        default: return "list.bullet.rectangle"
        }
    }
}
