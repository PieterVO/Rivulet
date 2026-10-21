// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Duration and easing of the driven vertical re-center scroll on Home rows and the below-fold
// detail. We drive it because the focus engine's own scroll animator races a CADisplayLink driver.
// Keep other timings (carousel morph, backdrop crossfade, detail slide) out of here.

import CoreGraphics
import Foundation

enum FocusScrollMotion {
    /// Default duration, in seconds, of the driven vertical focus-scroll settle.
    static let settleDuration: CFTimeInterval = 0.6

    /// Eased progress for the focus-scroll settle. Cubic ease-out: fast start,
    /// decelerating to a gentle stop. `t` is linear progress in 0...1.
    static func ease(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }

    // MARK: - Follow (the tvOS focus-scroll model)

    /// Fraction of the remaining distance left after each millisecond (time constant ~151 ms).
    static let convergencePerMillisecond = 0.9934
    /// Largest speed-up allowed per second: 10 pt per 60 Hz frame, per frame.
    static let maxAcceleration: CGFloat = 10 * 60 * 60
    /// Edge margin the focused item keeps when a long list scrolls.
    static let edgeInset: CGFloat = 180

    /// One frame of a retargetable follow: exponential easing toward `target`,
    /// with speed-ups capped so a start or a retarget never jumps. A target
    /// more than two viewports away is first brought to two viewports.
    /// `velocity` is in points per second; feed the returned one back in.
    static func follow(from y: CGFloat, to target: CGFloat, velocity: CGFloat,
                       dt: CFTimeInterval, viewport: CGFloat) -> (y: CGFloat, velocity: CGFloat, done: Bool) {
        let dt = min(max(dt, 1.0 / 240), 0.05)
        var y = y
        if viewport > 0, abs(target - y) > 2 * viewport {
            y = target - (target > y ? 2 : -2) * viewport
        }
        let k = CGFloat(pow(convergencePerMillisecond, dt * 1000))
        var delta = (target - y) * (1 - k)
        let speed = abs(delta) / CGFloat(dt)
        let prior = velocity * delta > 0 ? abs(velocity) : 0
        if speed > prior {
            let capped = min(speed, prior + maxAcceleration * CGFloat(dt))
            delta = (delta < 0 ? -capped : capped) * CGFloat(dt)
        }
        y += delta
        if abs(target - y) < 0.5 { return (target, 0, true) }
        return (y, delta / CGFloat(dt), false)
    }

    /// Smallest offset change that keeps `frame` at least `edgeInset` inside a
    /// viewport of `height` resting at `offset`. An item too tall to fit is centred.
    static func minimalOffset(revealing frame: CGRect, from offset: CGFloat, height: CGFloat) -> CGFloat {
        let inset = height >= 2 * edgeInset ? edgeInset : 0
        if frame.height > height - 2 * inset { return frame.midY - height / 2 }
        if frame.minY < offset + inset { return frame.minY - inset }
        if frame.maxY > offset + height - inset { return frame.maxY - height + inset }
        return offset
    }
}
