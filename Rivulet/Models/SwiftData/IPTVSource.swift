// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  IPTVSource.swift
//  Rivulet
//
//  Created by Bain Gurley on 11/28/25.
//

import Foundation
import SwiftData

/// Type of IPTV source
enum IPTVSourceType: String, Codable {
    case dispatcharr
    case genericM3U
}

/// Configuration for an IPTV source (Dispatcharr or generic M3U)
@Model
final class IPTVSource {
    @Attribute(.unique) var id: UUID
    var sourceType: IPTVSourceType
    var name: String
    var baseURL: String?      // For Dispatcharr (e.g., http://192.168.1.100:9191)
    var m3uURL: String?       // Direct M3U playlist URL
    var epgURL: String?       // XMLTV EPG URL
    var lastSync: Date?
    var channelCount: Int

    @Relationship(deleteRule: .cascade)
    var channels: [Channel] = []

    var configuration: ServerConfiguration?

    init(sourceType: IPTVSourceType, name: String) {
        self.id = UUID()
        self.sourceType = sourceType
        self.name = name
        self.channelCount = 0
    }

    /// Computed M3U URL for Dispatcharr sources
    var resolvedM3UURL: String? {
        switch sourceType {
        case .dispatcharr:
            guard let base = baseURL else { return nil }
            return "\(base)/output/m3u"
        case .genericM3U:
            return m3uURL
        }
    }

    /// Computed EPG URL for Dispatcharr sources
    var resolvedEPGURL: String? {
        switch sourceType {
        case .dispatcharr:
            guard let base = baseURL else { return nil }
            return "\(base)/output/epg"
        case .genericM3U:
            return epgURL
        }
    }
}
