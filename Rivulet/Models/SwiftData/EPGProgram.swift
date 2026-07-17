// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EPGProgram.swift
//  Rivulet
//
//  Created by Bain Gurley on 11/28/25.
//

import Foundation
import SwiftData

/// Electronic Program Guide entry from XMLTV
@Model
final class EPGProgram {
    @Attribute(.unique) var id: UUID
    var programId: String       // From XMLTV
    var title: String
    var subtitle: String?
    var programDescription: String?
    var startTime: Date
    var endTime: Date
    var category: String?
    var iconURL: String?
    var episodeNum: String?
    var isNew: Bool

    var channel: Channel?

    init(programId: String, title: String, startTime: Date, endTime: Date) {
        self.id = UUID()
        self.programId = programId
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.isNew = false
    }

    /// Check if program is currently airing
    var isCurrentlyAiring: Bool {
        let now = Date()
        return startTime <= now && endTime > now
    }

    /// Duration in minutes
    var durationMinutes: Int {
        Int(endTime.timeIntervalSince(startTime) / 60)
    }

    /// Formatted time range (e.g., "8:00 PM - 9:00 PM")
    var timeRangeFormatted: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: startTime)) - \(formatter.string(from: endTime))"
    }

    /// Progress through program (0.0 - 1.0) if currently airing
    var currentProgress: Double? {
        guard isCurrentlyAiring else { return nil }
        let now = Date()
        let elapsed = now.timeIntervalSince(startTime)
        let total = endTime.timeIntervalSince(startTime)
        return elapsed / total
    }
}
