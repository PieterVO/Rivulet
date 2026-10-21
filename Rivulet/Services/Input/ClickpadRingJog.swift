// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Clickpad ring jog, ported from UIKit's private `_UIRotaryGestureRecognizer` (read on tvOS 26.5):
/// wheel runs clockwise from 12 o'clock, a turn is weighted by 2.5 × radius (full at 0.4), and a
/// touch is a jog if it turns `15 / radius` degrees before its radius moves the threshold.
/// Feed absolute `GCMicroGamepad` dpad values (-1...1, y up); (0, 0) is a lift.
/// Speed is AVKit's: 100 points per weighted revolution, scaled by velocity, on the 1760-point bar.
struct ClickpadRingJog {
    /// Radius change that makes a touch a swipe.
    static let directionalThreshold = 0.15
    /// Numerator of the angle threshold: `clamp(15 / radius, 1, 179)` degrees.
    static let angleThresholdNumerator = 15.0
    /// A touch starting nearer the centre than this never jogs (0.20 at the top).
    static let minimumStartRadius = 0.23
    static let minimumStartRadiusTop = 0.20
    /// While a jog runs, samples nearer the centre than this move nothing.
    static let centreDeadzone = 0.2

    enum Classification: Equatable { case undecided, jog, swipe }

    private(set) var classification = Classification.undecided
    private var startRadius = 0.0
    private var started = false
    private var lastWheel: Double?
    /// Unweighted turn since the touch began, while undecided.
    private var undecidedTurn = 0.0
    /// The last few raw wheel moves, for the delta and velocity UIKit averages over.
    private var recent: [(time: Double, delta: Double)] = []
    /// Weighted revolutions per second over the last five samples.
    private(set) var velocity = 0.0

    static let velocitySamples = 5
    /// UIKit floors each sample's interval at 1/66 s; the floor applies to the
    /// whole window here, since GameController may sample faster than that.
    static let minimumSampleInterval = 1.0 / 66
    static let barWidth = 1760.0
    static let pointsPerRevolution = 100.0

    /// Seconds of a `duration`-long title that a weighted `turn` scrubs at `velocity`.
    static func seconds(forTurn turn: Double, velocity: Double, duration: Double) -> Double {
        let speed = abs(velocity)
        // AVKit's gain: 0.75 + v below one revolution a second, easing toward 2.75 above.
        let gain = speed < 1 ? speed + 0.75 : 2.75 - 1 / speed
        return turn * pointsPerRevolution * gain / barWidth * duration
    }

    var isJogging: Bool { classification == .jog }

    /// Where the finger sits on the wheel (clockwise fraction from 12 o'clock),
    /// once the touch is a jog. AVKit's ring dot tracks this, not the scrub.
    var fingerPosition: Double? { isJogging ? lastWheel : nil }

    /// Returns the weighted turn since the last sample in revolutions (clockwise
    /// positive) once the touch is a jog, otherwise nil.
    mutating func feed(x: Float, y: Float, time: Double = 0) -> Double? {
        guard x != 0 || y != 0 else {
            reset()
            return nil
        }
        // GameController reports y up; the digitizer runs y down from the top edge.
        let dx = Double(x) / 2, dy = -Double(y) / 2
        let radius = max((dx * dx + dy * dy).squareRoot(), 1e-6)
        let wheel = Self.wheelPosition(dx: dx, dy: dy)
        defer { lastWheel = wheel }

        guard started else {
            started = true
            startRadius = radius
            let top = wheel < 0.125 || wheel > 0.875
            if radius < (top ? Self.minimumStartRadiusTop : Self.minimumStartRadius) { classification = .swipe }
            return nil
        }
        guard classification != .swipe, let lastWheel else { return nil }
        let raw = Self.wrapped(wheel - lastWheel)

        if classification == .undecided {
            undecidedTurn += raw
            let radial = abs(radius - startRadius)
            let floor = Self.minimumStartRadius
                - (Self.minimumStartRadius - 0.18) * min(1, radial / Self.directionalThreshold)
            if radius < floor { classification = .swipe; return nil }
            let degrees = abs(undecidedTurn) * 360
            let angleThreshold = min(179, max(1, Self.angleThresholdNumerator / radius))
            let turned = degrees / angleThreshold, moved = radial / Self.directionalThreshold
            if turned >= 1 || moved >= 1 {
                classification = turned >= moved ? .jog : .swipe
                // UIKit begins with zero delta and fresh samples.
                recent = []
                velocity = 0
            }
            return classification == .jog ? 0 : nil
        }

        let weight = 2.5 * radius
        if radius < Self.centreDeadzone {
            velocity = 0
            return 0
        }
        updateVelocity(raw: raw, time: time, weight: weight)
        let deltas = recent.suffix(Self.velocitySamples).map(\.delta)
        return deltas.reduce(0, +) / Double(deltas.count) * weight
    }

    mutating func reset() {
        classification = .undecided
        started = false
        startRadius = 0
        lastWheel = nil
        undecidedTurn = 0
        recent = []
        velocity = 0
    }

    /// UIKit's rotary velocity: the recent moves over the time they took.
    private mutating func updateVelocity(raw: Double, time: Double, weight: Double) {
        recent.append((time, raw))
        if recent.count > Self.velocitySamples + 1 { recent.removeFirst() }
        guard recent.count > 1, let first = recent.first, let last = recent.last else { return }
        let turned = recent.dropFirst().reduce(0) { $0 + $1.delta }
        velocity = turned / max(last.time - first.time, Self.minimumSampleInterval) * weight
    }

    /// Clockwise fraction of a turn from 12 o'clock, 0..<1.
    static func wheelPosition(dx: Double, dy: Double) -> Double {
        let angle = atan2(dx, -dy) / (2 * .pi)
        return angle < 0 ? angle + 1 : angle
    }

    /// Shortest signed difference between two wheel positions.
    private static func wrapped(_ delta: Double) -> Double {
        delta - delta.rounded()
    }
}
