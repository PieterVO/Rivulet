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
        let window = ReplayWindowLogic(invokedAt: 100, priorSubtitleTrackId: nil)
        XCTAssertFalse(window.shouldRevert(currentTime: 90))
        XCTAssertTrue(window.shouldRevert(currentTime: 100.5))
    }

    func testExtendsWindow() {
        var window = ReplayWindowLogic(invokedAt: 100, priorSubtitleTrackId: nil)
        window = window.extended(to: 130)
        XCTAssertFalse(window.shouldRevert(currentTime: 110))
        XCTAssertTrue(window.shouldRevert(currentTime: 130.1))
    }
}
