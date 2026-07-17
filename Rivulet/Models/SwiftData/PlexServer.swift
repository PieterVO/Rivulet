// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexServer.swift
//  Rivulet
//
//  Created by Bain Gurley on 11/28/25.
//

import Foundation
import SwiftData

/// Stores Plex server connection details
/// Note: Auth token is stored in UserDefaults (matching watchOS pattern), not SwiftData
@Model
final class PlexServer {
    @Attribute(.unique) var id: UUID
    var serverName: String
    var serverURL: String
    var machineIdentifier: String
    var clientIdentifier: String
    var version: String?
    var platform: String?
    var lastLibrarySync: Date?
    var owned: Bool

    var configuration: ServerConfiguration?

    init(
        serverName: String,
        serverURL: String,
        machineIdentifier: String,
        clientIdentifier: String,
        owned: Bool = true
    ) {
        self.id = UUID()
        self.serverName = serverName
        self.serverURL = serverURL
        self.machineIdentifier = machineIdentifier
        self.clientIdentifier = clientIdentifier
        self.owned = owned
    }
}
