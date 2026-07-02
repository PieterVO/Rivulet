//
//  ReplayWindowTests.swift
//  RivuletTests
//
//  Pure-logic tests for ReplayWindowLogic, the "What did they say?"
//  replay window: jump back 15s with subtitles temporarily on, then
//  auto-revert once playback passes the point where it was invoked.
//

import XCTest
@testable import Rivulet

final class ReplayWindowTests: XCTestCase {
    func testRevertsWhenPassingInvocationPoint() {
        var window = ReplayWindowLogic(invokedAt: 100, priorSubtitleTrackId: nil)
        window = window.observing(currentTime: 90)
        XCTAssertFalse(window.shouldRevert(currentTime: 90))
        XCTAssertTrue(window.shouldRevert(currentTime: 100.5))
    }

    func testExtendsWindow() {
        var window = ReplayWindowLogic(invokedAt: 100, priorSubtitleTrackId: nil)
        window = window.observing(currentTime: 90)
        window = window.extended(to: 130)
        XCTAssertFalse(window.shouldRevert(currentTime: 110))
        XCTAssertTrue(window.shouldRevert(currentTime: 130.1))
    }

    /// The seek in `replayWithCaptions()` lands asynchronously (in a Task),
    /// but the window is armed synchronously before that. A stale
    /// time-observer tick at/after invokedAt can fire before the seek
    /// actually lands — that must NOT trigger a revert. Only once playback
    /// has actually been observed *before* invokedAt (i.e. the seek has
    /// landed) should a subsequent pass back over invokedAt revert.
    func testDoesNotRevertBeforeArmed() {
        var window = ReplayWindowLogic(invokedAt: 100, priorSubtitleTrackId: nil)
        // Stale tick at/after invokedAt before the seek lands: no revert.
        XCTAssertFalse(window.shouldRevert(currentTime: 100.5))
        // Once a tick below invokedAt arrives, the window arms...
        window = window.observing(currentTime: 90)
        // ...and reverts when passing the invocation point again.
        XCTAssertTrue(window.shouldRevert(currentTime: 100.5))
    }
}
