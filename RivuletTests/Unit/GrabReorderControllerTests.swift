// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class GrabReorderControllerTests: XCTestCase {

    private func target(_ from: Int, _ heading: UIFocusHeading,
                        _ axis: GrabReorderController.Axis, count: Int) -> Int? {
        GrabReorderController.target(from: from, direction: heading, axis: axis, count: count)
    }

    func test_target_vertical_upDown() {
        XCTAssertEqual(target(3, .up, .vertical, count: 6), 2)
        XCTAssertEqual(target(3, .down, .vertical, count: 6), 4)
        XCTAssertNil(target(3, .left, .vertical, count: 6), "a list has no sideways move")
        XCTAssertNil(target(3, .right, .vertical, count: 6))
    }

    func test_target_grid_leftRightWithinRowAndAcross() {
        let grid = GrabReorderController.Axis.grid(columns: 6)
        XCTAssertEqual(target(2, .left, grid, count: 20), 1)
        XCTAssertEqual(target(2, .right, grid, count: 20), 3)
        XCTAssertEqual(target(5, .right, grid, count: 20), 6, "the row's last slot steps onto the next row")
        XCTAssertEqual(target(6, .left, grid, count: 20), 5, "the row's first slot steps back onto the row above")
    }

    func test_target_grid_upDownByColumns() {
        let grid = GrabReorderController.Axis.grid(columns: 6)
        XCTAssertEqual(target(8, .up, grid, count: 20), 2)
        XCTAssertEqual(target(8, .down, grid, count: 20), 14)
    }

    func test_target_clampsAtEnds() {
        XCTAssertNil(target(0, .up, .vertical, count: 6))
        XCTAssertNil(target(5, .down, .vertical, count: 6))
        let grid = GrabReorderController.Axis.grid(columns: 6)
        XCTAssertNil(target(0, .left, grid, count: 20))
        XCTAssertNil(target(19, .right, grid, count: 20))
        XCTAssertNil(target(3, .up, grid, count: 20), "the top row stays put")
        XCTAssertNil(target(18, .down, grid, count: 20), "the last row stays put")
        XCTAssertEqual(target(10, .down, grid, count: 15), 14, "a short last row takes its last slot")
        XCTAssertNil(target(0, .down, grid, count: 1))
    }
}
