//
//  ShuttleGrammar.swift
//  Rivulet
//
//  Pure FF/RW shuttle grammar: click-and-hold enters shuttle at level 1,
//  clicks in the same direction bump up to the level 3 cap, clicks in the
//  opposite direction step down and cancel below level 1. Badges show the
//  human ladder (2x/4x/6x); actual cruise rates are 15x/60x/240x realtime.
//

import Foundation

nonisolated enum ShuttleGrammar {
    static let maxLevel = 3

    /// Badge numbers shown to the user per level (index 0 unused).
    /// Deliberately NOT the literal rates below — the badge speaks the
    /// familiar DVR shuttle ladder (2x/4x/6x = level, not multiple);
    /// a literal "240x" reads as a bug, not a speed.
    static let multipliers: [Int] = [0, 2, 4, 6]

    /// Content-seconds per real-second at each level. DVR-style ladder
    /// (each level 4x the previous): near-realtime multiples read as a
    /// stationary playhead on a long timeline, so the gentlest useful
    /// cruise is ~15x. Single tuning point for device feel.
    static let ratesPerLevel: [TimeInterval] = [0, 15, 60, 240]

    static func step(current: Int, clickForward: Bool) -> Int {
        let clickSign = clickForward ? 1 : -1
        if current == 0 { return clickSign }
        if (current > 0) == clickForward {
            return min(abs(current) + 1, maxLevel) * clickSign
        }
        // Opposite direction: step toward zero.
        return (abs(current) - 1) * (current > 0 ? 1 : -1)
    }

    static func rate(forLevel level: Int) -> TimeInterval {
        let idx = min(abs(level), maxLevel)
        return ratesPerLevel[idx]
    }

    static func badge(forSpeed speed: Int) -> String? {
        guard speed != 0 else { return nil }
        let glyph = speed > 0 ? "▶" : "◀"
        return "\(glyph) \(multipliers[min(abs(speed), maxLevel)])x"
    }
}
