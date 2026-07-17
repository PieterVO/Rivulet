// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  Channel.swift
//  Rivulet
//
//  Created by Bain Gurley on 11/28/25.
//

import Foundation
import SwiftData

/// Represents an IPTV channel from M3U playlist
@Model
final class Channel {
    @Attribute(.unique) var id: UUID
    var channelNumber: Int?
    var channelName: String
    var streamURL: String
    var logoURL: String?
    var tvgId: String?        // For EPG matching
    var tvgName: String?
    var groupTitle: String?   // Category (stored for future use)

    var source: IPTVSource?

    @Relationship(deleteRule: .cascade)
    var favorite: FavoriteChannel?

    @Relationship(deleteRule: .cascade)
    var epgPrograms: [EPGProgram] = []

    init(channelName: String, streamURL: String) {
        self.id = UUID()
        self.channelName = channelName
        self.streamURL = streamURL
    }

    /// Current program based on EPG data
    var currentProgram: EPGProgram? {
        let now = Date()
        return epgPrograms.first { $0.startTime <= now && $0.endTime > now }
    }

    /// Next program after current
    var nextProgram: EPGProgram? {
        guard let current = currentProgram else { return epgPrograms.first }
        return epgPrograms.first { $0.startTime >= current.endTime }
    }
}
