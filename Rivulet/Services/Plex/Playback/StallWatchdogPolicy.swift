// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  StallWatchdogPolicy.swift
//  Rivulet
//
//  Pure decision for whether the Aether stall watchdog is allowed to kick a
//  session (seek + play) after it has been buffering for the recovery delay.
//
//  Issue #247: a session the user PAUSED reported buffering once the tvOS
//  screensaver came up, the watchdog's kick fired 20s later, and the media
//  restarted under the screensaver. Two things were missing. The watchdog
//  never asked whether the user was trying to watch, and the screensaver is a
//  foreground-INACTIVE state, not a background transition, so none of the
//  background teardown/restore machinery covers it. Both are inputs here.
//

import Foundation
import UIKit

enum StallWatchdogPolicy {

    /// Whether the watchdog may arm at all.
    ///
    /// Buffering reported for a paused session is not a stall — there is
    /// nothing to recover, because nobody asked for playback. Arming anyway
    /// leaves a 20s timer pointed at a session the user deliberately parked.
    static func shouldArm(
        userIntendsToPlay: Bool,
        playbackState: UniversalPlaybackState
    ) -> Bool {
        guard userIntendsToPlay else { return false }
        // `.buffering` is the state that arms the watchdog in the first place;
        // `.playing` covers the buffering-flag-set-before-state-flip ordering.
        switch playbackState {
        case .playing, .buffering, .loading, .ready:
            return true
        case .idle, .paused, .ended, .failed:
            return false
        }
    }

    /// Whether the armed watchdog may actually kick, re-evaluated at fire time.
    ///
    /// The recovery delay is long enough that the world changes underneath it:
    /// the user can pause, or the screensaver can take over, in the 20s between
    /// arming and firing. A kick is a seek + `play()`, which on the Aether route
    /// can also rebuild the whole session (`play()` runs a pending foreground
    /// reload), so firing it against a paused or inactive app is exactly the
    /// visible restart of #247.
    ///
    /// - Parameter applicationState: `UIApplication.shared.applicationState`.
    ///   Only `.active` qualifies: `.inactive` is the screensaver / Control
    ///   Center / incoming-alert case, and `.background` is a torn-down engine.
    static func shouldKick(
        userIntendsToPlay: Bool,
        playbackState: UniversalPlaybackState,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState == .active else { return false }
        return shouldArm(userIntendsToPlay: userIntendsToPlay, playbackState: playbackState)
    }
}
