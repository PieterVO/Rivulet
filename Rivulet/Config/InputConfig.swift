// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Shared constants for remote, controller and keyboard input.

import Foundation

enum InputConfig {
    static let holdThreshold: TimeInterval = 0.4
    static let seekCoalesceInterval: TimeInterval = 0.05
    static let actionDedupeWindow: TimeInterval = 0.08
    static let transportDedupeWindow: TimeInterval = 0.35
    /// Cross-source window that merges two `.scrubNudge`s from one hold (a press plus an
    /// MPRemoteCommand seek) so the shuttle steps once. Same-source re-clicks are never
    /// deduped. Above the async skew, below a fast deliberate double-click.
    static let scrubNudgeDedupeWindow: TimeInterval = 0.25
    static let blockDismissTimeout: TimeInterval = 0.3

    /// Single-press Left/Right skip. Applied uniformly across every remote and
    /// focus state (content-focused, IR d-pad, keyboard, and the focused
    /// scrubber). User-configurable via Settings → Playback → Skip Length.
    static var tapSeekSeconds: TimeInterval {
        TimeInterval(SettingsStore.int(SkipInterval.storageKey, default: SkipInterval.defaultValue.rawValue))
    }
    /// Single-press Left skip. Follows Skip Forward until Settings → Playback →
    /// Skip Back Length is set (#335).
    static var tapSeekBackSeconds: TimeInterval {
        TimeInterval(SettingsStore.int(SkipInterval.backStorageKey, default: Int(tapSeekSeconds)))
    }
    /// Signed single-press skip for a direction.
    static func tapSeekDelta(forward: Bool) -> TimeInterval {
        forward ? tapSeekSeconds : -tapSeekBackSeconds
    }
    static let jumpSeekSeconds: TimeInterval = 30

    static let dpadThreshold: Float = 0.3
    /// How far out a touch must rest for a clickpad `.select` to count as a
    /// Left/Right EDGE click (1st-generation Siri Remote, whose clicks all
    /// arrive as `.select`). Stricter than `dpadThreshold` because a wrong yes
    /// skips the video instead of showing the controls.
    static let edgeClickThreshold: Float = 0.6
    static let joystickDeadzone: Float = 0.2

    /// Left/right region of a Siri Remote clickpad touch in absolute dpad
    /// coordinates: true = right, false = left, nil = anything else.
    ///
    /// Horizontal must DOMINATE, not just clear the threshold. An x-only test
    /// read every Up or Down click made slightly off the vertical axis (say
    /// x 0.35, y 0.9) as a Right click, so one press both raised the rail and
    /// queued a skip.
    static func clickpadHorizontalDirection(x: Float, y: Float, threshold: Float = dpadThreshold) -> Bool? {
        guard abs(x) > threshold, abs(x) > abs(y) else { return nil }
        return x > 0
    }

    /// Jog turn batched before one scrub step (about 1.8°).
    static let wheelEmitRevolutions = 0.005
}
