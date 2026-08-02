// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  StagedMenuBackTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

// MARK: - Stage-1 policy

final class StagedMenuBackPolicyTests: XCTestCase {

    func testReturnsToTopFromBelowTheTopSection() {
        XCTAssertTrue(StagedMenuBack.shouldReturnToTop(focusedSection: 4, topSection: 0))
    }

    func testPassesThroughAtTheTopSection() {
        XCTAssertFalse(StagedMenuBack.shouldReturnToTop(focusedSection: 0, topSection: 0))
    }

    /// Search has no hero, so its top section is 0; hero pages top out at the
    /// hero's own index.
    func testHonoursANonZeroTopSection() {
        XCTAssertFalse(StagedMenuBack.shouldReturnToTop(focusedSection: 2, topSection: 2))
        XCTAssertTrue(StagedMenuBack.shouldReturnToTop(focusedSection: 3, topSection: 2))
    }

    /// A section above the top (shouldn't happen, but must not consume the
    /// press and strand the user with no way back).
    func testPassesThroughAboveTheTopSection() {
        XCTAssertFalse(StagedMenuBack.shouldReturnToTop(focusedSection: 1, topSection: 2))
    }

    func testPassesThroughWhenNoSectionOwnsFocus() {
        XCTAssertFalse(StagedMenuBack.shouldReturnToTop(focusedSection: nil, topSection: 0))
    }
}

// MARK: - Press-phase swallow state

final class MenuPressSwallowStateTests: XCTestCase {

    /// A consumed press must withhold both its `.began` and its `.ended`, or
    /// the system sees half a press.
    func testWithholdsBothPhasesOfAConsumedPress() {
        var state = MenuPressSwallowState()
        XCTAssertTrue(state.shouldWithhold(press: nil, began: true, finished: false, handle: { true }))
        XCTAssertTrue(state.isSwallowing)
        XCTAssertTrue(state.shouldWithhold(press: nil, began: false, finished: true, handle: { true }))
        XCTAssertFalse(state.isSwallowing)
    }

    func testForwardsBothPhasesOfADeclinedPress() {
        var state = MenuPressSwallowState()
        XCTAssertFalse(state.shouldWithhold(press: nil, began: true, finished: false, handle: { false }))
        XCTAssertFalse(state.isSwallowing)
        XCTAssertFalse(state.shouldWithhold(press: nil, began: false, finished: true, handle: { false }))
    }

    /// The handler is consulted once per press — on `.began` only. Asking again
    /// on `.ended` would run the scroll twice.
    func testHandlerIsAskedOnlyOnBegan() {
        var state = MenuPressSwallowState()
        var asked = 0
        _ = state.shouldWithhold(press: nil, began: true, finished: false, handle: { asked += 1; return true })
        _ = state.shouldWithhold(press: nil, began: false, finished: false, handle: { asked += 1; return true })
        _ = state.shouldWithhold(press: nil, began: false, finished: true, handle: { asked += 1; return true })
        XCTAssertEqual(asked, 1)
    }

    /// Intermediate phases between began and ended stay withheld.
    func testWithholdsIntermediatePhases() {
        var state = MenuPressSwallowState()
        _ = state.shouldWithhold(press: nil, began: true, finished: false, handle: { true })
        XCTAssertTrue(state.shouldWithhold(press: nil, began: false, finished: false, handle: { true }))
        XCTAssertTrue(state.isSwallowing)
    }

    /// A cancelled press ends the swallow just like `.ended` — otherwise the
    /// state latches and every later Menu press is eaten.
    func testCancelledPressClearsTheSwallow() {
        var state = MenuPressSwallowState()
        _ = state.shouldWithhold(press: nil, began: true, finished: false, handle: { true })
        _ = state.shouldWithhold(press: nil, began: false, finished: true, handle: { true })
        XCTAssertFalse(state.isSwallowing)
        // Next press is free to be declined and forwarded.
        XCTAssertFalse(state.shouldWithhold(press: nil, began: true, finished: false, handle: { false }))
    }

    /// A single event carrying both phases must not latch the swallow on.
    func testSingleEventCarryingBothPhasesDoesNotLatch() {
        var state = MenuPressSwallowState()
        XCTAssertTrue(state.shouldWithhold(press: nil, began: true, finished: true, handle: { true }))
        XCTAssertFalse(state.isSwallowing)
    }

    /// A stray `.ended` with no preceding consumed `.began` must be forwarded,
    /// not eaten.
    func testStrayEndedIsForwarded() {
        var state = MenuPressSwallowState()
        XCTAssertFalse(state.shouldWithhold(press: nil, began: false, finished: true, handle: { true }))
    }

    /// A repeat `.began` for the SAME press must not re-ask the handler — that
    /// press owns the state until its own terminal phase.
    func testRepeatBeganForTheSamePressDoesNotReAsk() {
        var state = MenuPressSwallowState()
        // Held for the duration: identity comparison needs the press alive.
        let press = NSObject()
        var asked = 0
        XCTAssertTrue(state.shouldWithhold(press: press, began: true, finished: false,
                                           handle: { asked += 1; return true }))
        XCTAssertTrue(state.shouldWithhold(press: press, began: true, finished: false,
                                           handle: { asked += 1; return true }))
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(state.isSwallowing)
        XCTAssertTrue(state.shouldWithhold(press: press, began: false, finished: true, handle: { true }))
        XCTAssertFalse(state.isSwallowing)
    }

    /// Regression: a consumed press whose terminal phase never arrives must not
    /// eat the NEXT press. The handler's own navigation can route the `.ended`
    /// to another window, and a latched swallow then withheld every other Menu
    /// press whole — no handler asked, nothing delivered to the system, no way
    /// back out.
    func testNewPressIsAskedWhenThePendingOneNeverEnded() {
        var state = MenuPressSwallowState()
        let first = NSObject()
        let second = NSObject()
        var asked = 0

        XCTAssertTrue(state.shouldWithhold(press: first, began: true, finished: false,
                                           handle: { asked += 1; return true }))
        // `first`'s .ended never reaches the window. The user presses again.
        XCTAssertFalse(state.shouldWithhold(press: second, began: true, finished: false,
                                            handle: { asked += 1; return false }))
        XCTAssertEqual(asked, 2, "the new press must reach a handler")
        XCTAssertFalse(state.isSwallowing, "a declined press leaves nothing pending")
    }

    /// An unidentifiable press is treated as new rather than swallowed: a
    /// missed swallow is recoverable, a dead Menu button is not.
    func testUnidentifiedPressIsAlwaysAsked() {
        var state = MenuPressSwallowState()
        var asked = 0
        XCTAssertTrue(state.shouldWithhold(press: nil, began: true, finished: false,
                                           handle: { asked += 1; return true }))
        XCTAssertTrue(state.shouldWithhold(press: nil, began: true, finished: false,
                                           handle: { asked += 1; return true }))
        XCTAssertEqual(asked, 2)
    }

    /// The declined case must stay re-askable: no swallow is pending, so a
    /// following `.began` is a fresh decision.
    func testBeganAfterADeclinedPressIsAskedAgain() {
        var state = MenuPressSwallowState()
        var asked = 0
        XCTAssertFalse(state.shouldWithhold(press: nil, began: true, finished: false, handle: { asked += 1; return false }))
        XCTAssertFalse(state.shouldWithhold(press: nil, began: true, finished: false, handle: { asked += 1; return false }))
        XCTAssertEqual(asked, 2)
    }
}
