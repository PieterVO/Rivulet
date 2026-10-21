// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Tap-vs-hold for a Left/Right input: a release before `InputConfig.holdThreshold`
// is a tap, otherwise a hold. Shared by every source that delivers seek as begin/end.

import Foundation

@MainActor
final class DirectionalPressDetector {
    private var timer: Timer?
    private var forward: Bool?
    private var holdFired = false

    /// Fires once, `InputConfig.holdThreshold` after `begin(forward:)`, if
    /// `end`/`cancel` hasn't already happened.
    var onHold: ((Bool) -> Void)?
    /// Fires from `end()` when the release beat the hold threshold — the
    /// forward direction of the tap that just completed.
    var onTap: ((Bool) -> Void)?

    /// Starts the tap-vs-hold window for a press; a new press replaces any open one.
    func begin(forward: Bool) {
        self.forward = forward
        holdFired = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: InputConfig.holdThreshold, repeats: false) { [weak self] _ in
            // `assumeIsolated`, not a Task hop: the hold must mark itself fired synchronously,
            // or a release in between emits a tap and then the hold fires too.
            MainActor.assumeIsolated {
                guard let self, let forward = self.forward else { return }
                self.holdFired = true
                self.onHold?(forward)
            }
        }
    }

    /// Ends the in-progress press. Does nothing if the hold already fired
    /// (that press already committed to a hold action) or if there is no
    /// press in progress. `tapOverride`, when non-nil, replaces the default
    /// `onTap(forward)` call — used by callers (keyboard's Shift-modified
    /// arrow) that need a different action for the same tap.
    func end(tapOverride: (() -> Void)? = nil) {
        timer?.invalidate()
        timer = nil
        defer { forward = nil; holdFired = false }
        guard !holdFired, let forward else { return }
        if let tapOverride {
            tapOverride()
        } else {
            onTap?(forward)
        }
    }

    /// Discards the in-progress press without firing a tap (system
    /// interruption — `pressesCancelled`).
    func cancel() {
        timer?.invalidate()
        timer = nil
        forward = nil
        holdFired = false
    }
}
