// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  Whether the Aether stall watchdog may kick (seek + play) a session that has been
//  buffering. It must not kick a paused session or one under the screensaver, which is
//  foreground-inactive rather than backgrounded (#247).
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
    /// The user can pause or the screensaver can start in the 20 s before it fires, and a kick
    /// may rebuild the session. Only `.active` qualifies (`.inactive` is the screensaver).
    static func shouldKick(
        userIntendsToPlay: Bool,
        playbackState: UniversalPlaybackState,
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState == .active else { return false }
        return shouldArm(userIntendsToPlay: userIntendsToPlay, playbackState: playbackState)
    }
}
