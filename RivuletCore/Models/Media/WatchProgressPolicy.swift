// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WatchProgressPolicy.swift
//  Rivulet
//
//  The one definition of "has a resume point" and "how far in". Drawing a partial
//  progress bar (0 < fraction < 1) is a different rule and lives at the render sites.
//

import Foundation

enum WatchProgressPolicy {
    /// Below this, a resume point is noise the user does not want to be asked
    /// about (a few seconds of an accidental start).
    static let startedThreshold: Double = 0.02

    /// At or past this, the item counts as finished. Matches what Plex itself
    /// treats as watched, which is why an item this far in drops out of On Deck
    /// and shows the watched glyph rather than a resume offer.
    static let completionThreshold: Double = 0.9

    /// Fraction watched in [0, 1], or nil when there is no position or no
    /// runtime to measure it against. Capped, because Plex sometimes reports an
    /// offset slightly past the duration.
    static func progress(offsetSeconds: TimeInterval, runtimeSeconds: TimeInterval?) -> Double? {
        guard let runtime = runtimeSeconds, runtime > 0, offsetSeconds > 0 else { return nil }
        return min(1.0, offsetSeconds / runtime)
    }

    /// True when the item has a resume point worth offering. A missing runtime
    /// answers false. Played state is ignored: a rewatch has a real resume point.
    static func hasResumePoint(offsetSeconds: TimeInterval, runtimeSeconds: TimeInterval?) -> Bool {
        guard let fraction = progress(offsetSeconds: offsetSeconds, runtimeSeconds: runtimeSeconds) else {
            return false
        }
        return fraction > startedThreshold && fraction < completionThreshold
    }

    /// Position-only judgement, for `MediaUserState` and anything else that has
    /// a resume position but no runtime to measure it against. Any position
    /// counts, so the thresholds do not apply.
    static func hasResumePoint(offsetSeconds: TimeInterval) -> Bool {
        offsetSeconds > 0
    }
}
