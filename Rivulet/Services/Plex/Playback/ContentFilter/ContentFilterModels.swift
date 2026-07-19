// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContentFilterModels.swift
//  Rivulet
//
//  Value types for the local content filter (VidAngel/ClearPlay-style
//  real-time muting and scene skipping). Nothing here touches the media
//  file — filters are applied live during playback (mute the audio, or
//  seek past a scene), matching the client-side approach protected by the
//  Family Movie Act of 2005.
//

import Foundation
import SwiftUI

// MARK: - Severity

/// How strong a filtered word/scene is. Lets the user keep mild language while
/// still muting strong language. Ordered: `.mild < .moderate < .strong`.
nonisolated enum FilterSeverity: Int, Codable, Sendable, Comparable, CaseIterable, CustomStringConvertible {
    case mild = 0
    case moderate = 1
    case strong = 2

    static func < (lhs: FilterSeverity, rhs: FilterSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String {
        switch self {
        case .mild: return "Mild"
        case .moderate: return "Moderate"
        case .strong: return "Strong"
        }
    }

    /// Map an MCF/EDL severity token onto our scale.
    init(mcf raw: String) {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "low", "mild", "1":            self = .mild
        case "high", "severe", "strong", "3": self = .strong
        default:                            self = .moderate  // "medium"/"moderate"/unknown
        }
    }
}

// MARK: - Action

/// What the player does with a region: silence the audio, or seek past it.
nonisolated enum FilterAction: String, Codable, Sendable {
    case mute
    case skip

    /// Skip is the stronger action — when a cue asks for both, skip wins.
    static func strongest(_ a: FilterAction, _ b: FilterAction) -> FilterAction {
        (a == .skip || b == .skip) ? .skip : .mute
    }
}

// MARK: - Category

/// The kinds of content the filter can act on.
///
/// Text-detectable categories (`isTextDetectable`) are found automatically from
/// the subtitle track — no external data needed. Scene categories can only come
/// from an imported filter list (MCF/EDL), because dialogue text can't reveal a
/// silent violent or nude scene.
nonisolated enum FilterCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    // Detected from subtitle dialogue
    case profanity
    case blasphemy
    case slur
    case sexualLanguage
    // Scene-based (require an imported filter list)
    case violence
    case sexNudity
    case frightening
    case substances
    /// Anything an imported list tagged that we don't map to a specific bucket.
    case other

    var id: String { rawValue }

    /// True when the category can be found from subtitle text alone.
    var isTextDetectable: Bool {
        switch self {
        case .profanity, .blasphemy, .slur, .sexualLanguage: return true
        case .violence, .sexNudity, .frightening, .substances, .other: return false
        }
    }

    /// Default action when a filter list doesn't specify one. Language mutes;
    /// scenes skip.
    var defaultAction: FilterAction {
        isTextDetectable ? .mute : .skip
    }

    var displayName: String {
        switch self {
        case .profanity: return "Profanity"
        case .blasphemy: return "Blasphemy"
        case .slur: return "Slurs"
        case .sexualLanguage: return "Crude & Sexual Language"
        case .violence: return "Violence & Gore"
        case .sexNudity: return "Sex & Nudity"
        case .frightening: return "Frightening & Intense"
        case .substances: return "Drugs, Alcohol & Smoking"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .profanity: return "exclamationmark.bubble.fill"
        case .blasphemy: return "hands.clap.fill"
        case .slur: return "person.fill.xmark"
        case .sexualLanguage: return "heart.slash.fill"
        case .violence: return "burst.fill"
        case .sexNudity: return "eye.slash.fill"
        case .frightening: return "theatermasks.fill"
        case .substances: return "pills.fill"
        case .other: return "line.3.horizontal.decrease.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .profanity: return .orange
        case .blasphemy: return .yellow
        case .slur: return .red
        case .sexualLanguage: return .pink
        case .violence: return .red
        case .sexNudity: return .purple
        case .frightening: return .indigo
        case .substances: return .teal
        case .other: return .gray
        }
    }

    /// UserDefaults key for this category's on/off state.
    var enabledDefaultsKey: String { "contentFilter.\(rawValue).enabled" }

    /// Sensible default: everything on once the master filter is enabled.
    var defaultEnabled: Bool { true }

    /// Categories exposed as individual toggles in Settings, in display order.
    static let userToggleable: [FilterCategory] = [
        .profanity, .blasphemy, .slur, .sexualLanguage,
        .violence, .sexNudity, .frightening, .substances
    ]

    /// Map an arbitrary MCF/EDL category token onto our set. Resilient to the
    /// many spellings community filter files use in the wild.
    static func matching(_ raw: String) -> FilterCategory {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        for (needles, category) in categoryAliases {
            if needles.contains(where: { key.contains($0) }) { return category }
        }
        return .other
    }

    private static let categoryAliases: [(needles: [String], category: FilterCategory)] = [
        (["blasphem", "deity", "religio"], .blasphemy),
        (["slur", "racial", "racism", "ethnic"], .slur),
        (["nudity", "nude", "sex", "porn", "erotic", "intercourse"], .sexNudity),
        (["gore", "violen", "blood", "brutal", "torture", "murder"], .violence),
        (["fright", "horror", "disturb", "intense", "jump", "scary"], .frightening),
        (["drug", "alcohol", "smok", "substance", "narcotic", "drink"], .substances),
        (["profan", "language", "curse", "swear", "vulgar"], .profanity)
    ]
}

// MARK: - Region

/// A single time-coded filter window from an imported list.
nonisolated struct FilterRegion: Identifiable, Codable, Sendable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    let category: FilterCategory
    let severity: FilterSeverity
    let action: FilterAction

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

// MARK: - List

/// An imported, time-coded filter list for one title (parsed from MCF or EDL).
nonisolated struct ContentFilterList: Codable, Sendable {
    /// Regions sorted by start time.
    let regions: [FilterRegion]

    init(regions: [FilterRegion]) {
        self.regions = regions.sorted { $0.start < $1.start }
    }

    var isEmpty: Bool { regions.isEmpty }

    static let empty = ContentFilterList(regions: [])
}
