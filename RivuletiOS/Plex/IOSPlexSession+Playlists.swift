// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Video playlists on every server, read only: browse and play in order.
extension IOSPlexSession {
    /// Every server's video playlists, by `serverID ?? ""`. A server that fails keeps its last answer.
    func fetchVideoPlaylists() async -> [String: [PlexPlaylist]] {
        let ids: [String?] = [nil] + PlexExtraServers.shared.current.map(\.machineID)
        let servers = ids.map { ($0 ?? "", try? configuration(serverID: $0)) }
        let previous = videoPlaylists
        let network = network
        return await withTaskGroup(of: (String, [PlexPlaylist]?).self) { group in
            for (key, server) in servers {
                group.addTask {
                    guard let server else { return (key, nil) }
                    return (key, try? await network.getPlaylists(serverURL: server.serverURL, authToken: server.token, type: "video"))
                }
            }
            return await group.reduce(into: [:]) { result, answer in
                let lists = (answer.1 ?? previous[answer.0])?.sorted {
                    ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending
                }
                if let lists, !lists.isEmpty { result[answer.0] = lists }
            }
        }
    }

    func playlists(serverID: String?) -> [PlexPlaylist] { videoPlaylists[serverID ?? ""] ?? [] }

    /// A playlist's rows, stamped with their server.
    func playlistItems(_ playlist: PlexPlaylist, serverID: String?) async throws -> [PlexMetadata] {
        let (serverURL, token) = try configuration(serverID: serverID)
        let items = try await network.getAllPlaylistItems(serverURL: serverURL, authToken: token, ratingKey: playlist.ratingKey)
        return Self.onServer(items, serverID)
    }
}
