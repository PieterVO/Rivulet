//
//  ShuttleGrammar.swift
//  Rivulet
//
//  Pure FF/RW shuttle grammar: click-and-hold enters shuttle at level 1 (2x),
//  clicks in the same direction bump level 1 (2x) -> level 3 (6x) cap, clicks in
//  the opposite direction step down and cancel below level 1.
//

import Foundation

nonisolated enum ShuttleGrammar {
    static let maxLevel = 3

    /// Multipliers shown to the user per level (index 0 unused).
    static let multipliers: [Int] = [0, 2, 4, 6]

    /// Content-seconds per real-second at each level.
    /// Literal 2x/4x/6x realtime. Single tuning point if device feel
    /// says too slow for long content.
    static let ratesPerLevel: [TimeInterval] = [0, 2, 4, 6]

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
