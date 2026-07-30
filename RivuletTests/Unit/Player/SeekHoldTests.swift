// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SeekHoldTests.swift
//  RivuletTests
//
//  Pure-logic tests for SeekHoldLogic: hold the transport rail at a seek's
//  target until the picture lands there, so a clock tick that predates the
//  landing cannot snap the rail back to where the seek started.
//

import XCTest
@testable import Rivulet

final class SeekHoldTests: XCTestCase {

    func testHoldsAtTargetUntilLanding() {
        var hold = SeekHoldLogic()
        XCTAssertFalse(hold.isHolding)

        XCTAssertEqual(hold.apply(SeekHoldEvent(id: 1, outcome: .began, target: 900)), 900)
        XCTAssertTrue(hold.isHolding)
        XCTAssertEqual(hold.heldTime, 900)

        // Landing reports the rendered position, not the requested one:
        // keyframe granularity puts them a few seconds apart.
        XCTAssertEqual(hold.apply(SeekHoldEvent(id: 1, outcome: .landed(renderedTime: 897.5), target: 900)), 897.5)
        XCTAssertFalse(hold.isHolding)
        XCTAssertNil(hold.heldTime)
    }

    /// The case the whole thing exists for: on the software path a spent read
    /// budget is terminal and nothing re-issues the seek. Releasing shows the
    /// target, where the engine parks its clock, instead of freezing the rail
    /// on a landing that may never arrive.
    func testStallReleasesTheHoldWithoutMovingTheRail() {
        var hold = SeekHoldLogic()
        _ = hold.apply(SeekHoldEvent(id: 7, outcome: .began, target: 1800))

        XCTAssertNil(hold.apply(SeekHoldEvent(id: 7, outcome: .settledElsewhere, target: 1800)))
        XCTAssertFalse(hold.isHolding)
    }

    /// A supersede can be emitted either side of the replacing seek's `.began`,
    /// so the hold has to survive the overlap in both orders. A gap would let
    /// one pre-landing tick through, which is the snap-back.
    func testHoldSurvivesSupersedeInEitherOrder() {
        var supersedeLast = SeekHoldLogic()
        _ = supersedeLast.apply(SeekHoldEvent(id: 1, outcome: .began, target: 100))
        XCTAssertEqual(supersedeLast.apply(SeekHoldEvent(id: 2, outcome: .began, target: 200)), 200)
        XCTAssertNil(supersedeLast.apply(SeekHoldEvent(id: 1, outcome: .settledElsewhere, target: 100)))
        XCTAssertTrue(supersedeLast.isHolding)
        XCTAssertEqual(supersedeLast.heldTime, 200)

        var supersedeFirst = SeekHoldLogic()
        _ = supersedeFirst.apply(SeekHoldEvent(id: 1, outcome: .began, target: 100))
        _ = supersedeFirst.apply(SeekHoldEvent(id: 1, outcome: .settledElsewhere, target: 100))
        XCTAssertEqual(supersedeFirst.apply(SeekHoldEvent(id: 2, outcome: .began, target: 200)), 200)
        XCTAssertTrue(supersedeFirst.isHolding)
    }

    /// A `.stalled` seek stays alive inside AVPlayer as recovery intent, so a
    /// `.landed` can still arrive under the same id minutes later. It must not
    /// reopen a hold that is already closed.
    func testLateLandingAfterStallStillMovesTheRailOnce() {
        var hold = SeekHoldLogic()
        _ = hold.apply(SeekHoldEvent(id: 3, outcome: .began, target: 600))
        _ = hold.apply(SeekHoldEvent(id: 3, outcome: .settledElsewhere, target: 600))

        XCTAssertEqual(hold.apply(SeekHoldEvent(id: 3, outcome: .landed(renderedTime: 600), target: 600)), 600)
        XCTAssertFalse(hold.isHolding)
    }
}
