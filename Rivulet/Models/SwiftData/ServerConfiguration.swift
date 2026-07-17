// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ServerConfiguration.swift
//  Rivulet
//
//  Created by Bain Gurley on 11/28/25.
//

import Foundation
import SwiftData

/// Represents the type of server connection
enum ServerType: String, Codable {
    case plex
    case dispatcharr
    case genericIPTV
}

/// Base configuration for any server connection (Plex or IPTV)
@Model
final class ServerConfiguration {
    @Attribute(.unique) var id: UUID
    var name: String
    var serverType: ServerType
    var createdAt: Date
    var lastConnected: Date?
    var isActive: Bool

    // Relationships
    @Relationship(deleteRule: .cascade) var plexServer: PlexServer?
    @Relationship(deleteRule: .cascade) var iptvSource: IPTVSource?

    init(name: String, serverType: ServerType) {
        self.id = UUID()
        self.name = name
        self.serverType = serverType
        self.createdAt = Date()
        self.isActive = true
    }
}
