// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InputPressTrackerTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class InputPressTrackerTests: XCTestCase {
    private let threshold: TimeInterval = 0.4

    private func tracker() -> InputPressTracker {
        InputPressTracker(holdThreshold: threshold)
    }

    // MARK: Tap vs hold

    func test_quickRelease_isTap() {
        var t = tracker()
        XCTAssertNil(t.began("right", at: 100))
        let verdict = t.finished("right", at: 100.12, cancelled: false)
        XCTAssertEqual(verdict?.isHold, false)
        XCTAssertEqual(verdict.map { Int($0.duration * 1000) }, 120)
    }

    func test_releaseAtThreshold_isHold() {
        var t = tracker()
        _ = t.began("right", at: 100)
        XCTAssertEqual(t.finished("right", at: 100 + threshold, cancelled: false)?.isHold, true)
    }

    /// The #212 hypothesis: an IR remote whose release lands late turns every
    /// intended 30s skip into a shuttle.
    func test_lateRelease_readsAsHoldNotTap() {
        var t = tracker()
        _ = t.began("right", at: 0)
        XCTAssertEqual(t.finished("right", at: 0.55, cancelled: false)?.isHold, true)
    }

    // MARK: GameController correlation

    func test_noGamepadEvent_reportsNoGamepad() {
        var t = tracker()
        _ = t.began("left", at: 0)
        XCTAssertEqual(t.finished("left", at: 0.1, cancelled: false)?.sawGamepad, false)
    }

    func test_gamepadEventDuringPress_reportsGamepad() {
        var t = tracker()
        _ = t.began("left", at: 0)
        t.gamepadEvent()
        XCTAssertEqual(t.finished("left", at: 0.1, cancelled: false)?.sawGamepad, true)
    }

    func test_gamepadEventBeforePress_doesNotLeakIntoNextPress() {
        var t = tracker()
        t.gamepadEvent()
        _ = t.began("left", at: 0)
        XCTAssertEqual(t.finished("left", at: 0.1, cancelled: false)?.sawGamepad, false)
    }

    // MARK: Never-terminated presses

    func test_reBeganWhileOpen_warns() {
        var t = tracker()
        _ = t.began("right", at: 0)
        let warning = t.began("right", at: 1.0)
        XCTAssertEqual(warning, "right re-began with the previous press still open after 1000ms")
        XCTAssertEqual(t.openCount, 1, "the new press replaces the orphan rather than stacking")
    }

    func test_sweepStale_reportsAndDropsPressPastWindow() {
        var t = tracker()
        _ = t.began("right", at: 0)
        let now = InputPressTracker.staleAfter + 1
        XCTAssertEqual(t.sweepStale(now: now), ["right never terminated (open 4000ms)"])
        XCTAssertEqual(t.openCount, 0)
    }

    func test_sweepStale_leavesFreshPressAlone() {
        var t = tracker()
        _ = t.began("right", at: 0)
        XCTAssertTrue(t.sweepStale(now: 0.2).isEmpty)
        XCTAssertEqual(t.openCount, 1)
    }

    // MARK: Independence and edge cases

    func test_finishedWithoutBegan_yieldsNoVerdict() {
        var t = tracker()
        XCTAssertNil(t.finished("right", at: 1.0, cancelled: false))
    }

    func test_pressTypesTrackedIndependently() {
        var t = tracker()
        _ = t.began("left", at: 0)
        _ = t.began("select", at: 0.1)
        XCTAssertEqual(t.finished("left", at: 0.2, cancelled: false)?.isHold, false)
        XCTAssertEqual(t.finished("select", at: 0.9, cancelled: false)?.isHold, true)
        XCTAssertEqual(t.openCount, 0)
    }

    func test_cancelledPress_isFlagged() {
        var t = tracker()
        _ = t.began("select", at: 0)
        let verdict = t.finished("select", at: 0.5, cancelled: true)
        XCTAssertEqual(verdict?.cancelled, true)
        XCTAssertEqual(verdict?.isHold, true)
    }
}
