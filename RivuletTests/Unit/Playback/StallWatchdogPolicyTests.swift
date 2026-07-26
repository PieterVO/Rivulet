// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  StallWatchdogPolicyTests.swift
//  RivuletTests
//
//  Issue #247: pausing media and letting the tvOS screensaver come up
//  restarted playback. A paused Aether session reports buffering once the
//  display is taken over, the stall watchdog's 20s recovery kick (seek +
//  play, which on the Aether route can rebuild the whole session) fired, and
//  the media started again under the screensaver.
//
//  Pure tests over the arm/fire decision. UniversalPlayerViewModel's init
//  builds a real player and Combine graph, so the watchdog task itself is not
//  reachable from a unit test — this predicate is the testable seam.
//

import UIKit
import XCTest
@testable import Rivulet

final class StallWatchdogPolicyTests: XCTestCase {

    // MARK: - Arming

    func testArmsWhilePlaying() {
        XCTAssertTrue(
            StallWatchdogPolicy.shouldArm(userIntendsToPlay: true, playbackState: .playing)
        )
    }

    func testArmsWhileBuffering() {
        XCTAssertTrue(
            StallWatchdogPolicy.shouldArm(userIntendsToPlay: true, playbackState: .buffering)
        )
    }

    func testArmsWhileLoading() {
        XCTAssertTrue(
            StallWatchdogPolicy.shouldArm(userIntendsToPlay: true, playbackState: .loading)
        )
    }

    /// The bug's arming edge: a session the user paused can still report
    /// buffering, but there is nothing to recover.
    func testDoesNotArmWhenPaused() {
        XCTAssertFalse(
            StallWatchdogPolicy.shouldArm(userIntendsToPlay: false, playbackState: .paused)
        )
    }

    /// Intent is the authority, not engine state: tvOS auto-pauses the inner
    /// AVPlayer on resign-active, so a watching user's state can read .paused
    /// while intent is still true — and conversely a stale .buffering state
    /// must not out-vote a user who has pressed pause.
    func testDoesNotArmWhenIntentIsFalseEvenIfStateLooksActive() {
        XCTAssertFalse(
            StallWatchdogPolicy.shouldArm(userIntendsToPlay: false, playbackState: .buffering)
        )
        XCTAssertFalse(
            StallWatchdogPolicy.shouldArm(userIntendsToPlay: false, playbackState: .playing)
        )
    }

    func testDoesNotArmWhenIdleEndedOrFailed() {
        XCTAssertFalse(
            StallWatchdogPolicy.shouldArm(userIntendsToPlay: true, playbackState: .idle)
        )
        XCTAssertFalse(
            StallWatchdogPolicy.shouldArm(userIntendsToPlay: true, playbackState: .ended)
        )
        XCTAssertFalse(
            StallWatchdogPolicy.shouldArm(
                userIntendsToPlay: true,
                playbackState: .failed(.networkError("stalled"))
            )
        )
    }

    // MARK: - Firing

    func testKicksWhenActiveAndPlaying() {
        XCTAssertTrue(
            StallWatchdogPolicy.shouldKick(
                userIntendsToPlay: true,
                playbackState: .buffering,
                applicationState: .active
            )
        )
    }

    /// The exact #247 scenario: paused, screensaver up (inactive), buffering
    /// reported. Both guards independently refuse.
    func testDoesNotKickWhenPausedUnderScreensaver() {
        XCTAssertFalse(
            StallWatchdogPolicy.shouldKick(
                userIntendsToPlay: false,
                playbackState: .paused,
                applicationState: .inactive
            )
        )
    }

    /// The screensaver is a foreground-INACTIVE state, so it must be refused on
    /// the app-state axis alone, even for a user who genuinely wants playback.
    /// Kicking here would seek + play into a dimmed screen.
    func testDoesNotKickWhileInactiveEvenIfUserWantsPlayback() {
        XCTAssertFalse(
            StallWatchdogPolicy.shouldKick(
                userIntendsToPlay: true,
                playbackState: .buffering,
                applicationState: .inactive
            )
        )
    }

    func testDoesNotKickWhileBackgrounded() {
        XCTAssertFalse(
            StallWatchdogPolicy.shouldKick(
                userIntendsToPlay: true,
                playbackState: .buffering,
                applicationState: .background
            )
        )
    }

    /// The user pausing during the 20s recovery delay is why the fire-time
    /// re-check exists: arming was legitimate, firing is not.
    func testDoesNotKickWhenUserPausedDuringTheDelay() {
        XCTAssertTrue(
            StallWatchdogPolicy.shouldArm(userIntendsToPlay: true, playbackState: .buffering),
            "Arming was legitimate at the time"
        )
        XCTAssertFalse(
            StallWatchdogPolicy.shouldKick(
                userIntendsToPlay: false,
                playbackState: .paused,
                applicationState: .active
            ),
            "…but 20s later the user is paused, so the kick must not run"
        )
    }
}
