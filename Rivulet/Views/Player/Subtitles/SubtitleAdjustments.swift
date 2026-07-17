// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SubtitleAdjustments.swift
//  Rivulet
//
//  User-tunable subtitle timing and placement, surfaced as steppers inside
//  the OSD Subtitles panel (VOD rail and Live TV rail).
//
//  Delay is STICKY PER MEDIA: keyed by the Plex ratingKey for VOD and the
//  channel id for Live TV, so one channel can hold +3.0s while another stays
//  at the default. Height is GLOBAL: one offset applied to every overlay,
//  stored as whole units of `heightUnitPt` and clamped to ±`heightUnitMax`.
//

import Foundation
import CoreGraphics

enum SubtitleAdjustments {

    // MARK: - Delay (per media)

    /// One stepper press worth of delay, in seconds.
    static let delayStep: Double = 0.1

    private static let delayMapKey = "subtitleDelayByMedia"

    /// Stored delay for a media key ("plex:<ratingKey>" / "live:<channelId>").
    /// 0 when never adjusted.
    static func delay(forKey key: String) -> Double {
        let map = UserDefaults.standard.dictionary(forKey: delayMapKey) as? [String: Double]
        return map?[key] ?? 0
    }

    /// Persists `value` for `key`. A value of 0 removes the entry so the map
    /// only holds media the user actually adjusted.
    static func setDelay(_ value: Double, forKey key: String) {
        var map = (UserDefaults.standard.dictionary(forKey: delayMapKey) as? [String: Double]) ?? [:]
        if abs(value) < delayStep / 2 {
            map.removeValue(forKey: key)
        } else {
            map[key] = value
        }
        UserDefaults.standard.set(map, forKey: delayMapKey)
    }

    /// Rounds a raw delay to one decimal so repeated ±0.1 steps can't drift
    /// into binary-fraction noise (0.30000000000000004).
    static func roundedDelay(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    /// "0.0s", "+0.3s", "-1.2s" — the stepper's centre label.
    static func formattedDelay(_ value: Double) -> String {
        if abs(value) < delayStep / 2 { return "0.0s" }
        return String(format: "%+.1fs", value)
    }

    // MARK: - Height (global)

    /// Points moved per stepper press.
    static let heightUnitPt: CGFloat = 10
    /// Stepper range: ±10 units (±100 pt).
    static let heightUnitMax = 10

    /// Overlays read this via @AppStorage so a change re-renders them live;
    /// keep the literal in sync if this key ever moves.
    static let heightKey = "subtitleHeightUnits"

    /// Current height offset in UNITS (positive = subtitles sit higher).
    static var heightUnits: Int {
        clampUnits(UserDefaults.standard.integer(forKey: heightKey))
    }

    static func setHeightUnits(_ units: Int) {
        UserDefaults.standard.set(clampUnits(units), forKey: heightKey)
    }

    /// "0", "+3", "-2" — the stepper's centre label.
    static func formattedHeight(_ units: Int) -> String {
        units == 0 ? "0" : String(format: "%+d", units)
    }

    /// Extra bottom padding for the subtitle overlays, derived from the stored
    /// units. Overlays read the raw units via @AppStorage and convert here, so
    /// the units→points rule lives in one place.
    static func heightOffset(forUnits units: Int) -> CGFloat {
        CGFloat(clampUnits(units)) * heightUnitPt
    }

    private static func clampUnits(_ units: Int) -> Int {
        max(-heightUnitMax, min(heightUnitMax, units))
    }
}
