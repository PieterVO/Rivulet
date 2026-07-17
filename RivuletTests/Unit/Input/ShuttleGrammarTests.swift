// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ShuttleGrammarTests.swift
//  RivuletTests
//
//  Unit tests for the FF/RW shuttle grammar: hold enters at 2x, same-direction
//  clicks bump 2x -> 4x -> 6x cap, opposite-direction clicks step down then cancel.
//

import XCTest
@testable import Rivulet

final class ShuttleGrammarTests: XCTestCase {

    func testHoldEntersAtLevelOne() {
        XCTAssertEqual(ShuttleGrammar.step(current: 0, clickForward: true), 1)
        XCTAssertEqual(ShuttleGrammar.step(current: 0, clickForward: false), -1)
    }

    func testSameDirectionClicksBumpToCap() {
        // Forward: 1 -> 2 -> 3, capped at maxLevel (3).
        XCTAssertEqual(ShuttleGrammar.step(current: 1, clickForward: true), 2)
        XCTAssertEqual(ShuttleGrammar.step(current: 2, clickForward: true), 3)
        XCTAssertEqual(ShuttleGrammar.step(current: 3, clickForward: true), 3)

        // Backward: -1 -> -2 -> -3, capped at -maxLevel (-3).
        XCTAssertEqual(ShuttleGrammar.step(current: -1, clickForward: false), -2)
        XCTAssertEqual(ShuttleGrammar.step(current: -2, clickForward: false), -3)
        XCTAssertEqual(ShuttleGrammar.step(current: -3, clickForward: false), -3)
    }

    func testOppositeDirectionClicksStepDownThenCancel() {
        // From level 3 forward, opposite (backward) clicks step down: 3 -> 2 -> 1 -> 0.
        XCTAssertEqual(ShuttleGrammar.step(current: 3, clickForward: false), 2)
        XCTAssertEqual(ShuttleGrammar.step(current: 2, clickForward: false), 1)
        XCTAssertEqual(ShuttleGrammar.step(current: 1, clickForward: false), 0)

        // From level -3 backward, opposite (forward) clicks step down: -3 -> -2 -> -1 -> 0.
        XCTAssertEqual(ShuttleGrammar.step(current: -3, clickForward: true), -2)
        XCTAssertEqual(ShuttleGrammar.step(current: -2, clickForward: true), -1)
        XCTAssertEqual(ShuttleGrammar.step(current: -1, clickForward: true), 0)
    }

    func testRateAndBadge() {
        XCTAssertEqual(ShuttleGrammar.rate(forLevel: 0), 0)
        XCTAssertEqual(ShuttleGrammar.rate(forLevel: 1), 15)
        XCTAssertEqual(ShuttleGrammar.rate(forLevel: 2), 60)
        XCTAssertEqual(ShuttleGrammar.rate(forLevel: 3), 240)
        // rate(forLevel:) takes the magnitude — direction is irrelevant.
        XCTAssertEqual(ShuttleGrammar.rate(forLevel: -1), 15)
        XCTAssertEqual(ShuttleGrammar.rate(forLevel: -2), 60)
        XCTAssertEqual(ShuttleGrammar.rate(forLevel: -3), 240)

        XCTAssertNil(ShuttleGrammar.badge(forSpeed: 0))
        XCTAssertEqual(ShuttleGrammar.badge(forSpeed: 1), "▶ 2x")
        XCTAssertEqual(ShuttleGrammar.badge(forSpeed: 2), "▶ 4x")
        XCTAssertEqual(ShuttleGrammar.badge(forSpeed: 3), "▶ 6x")
        XCTAssertEqual(ShuttleGrammar.badge(forSpeed: -1), "◀ 2x")
        XCTAssertEqual(ShuttleGrammar.badge(forSpeed: -2), "◀ 4x")
        XCTAssertEqual(ShuttleGrammar.badge(forSpeed: -3), "◀ 6x")
    }
}
