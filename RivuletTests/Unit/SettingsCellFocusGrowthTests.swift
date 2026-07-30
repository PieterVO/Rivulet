// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsCellFocusGrowthTests.swift
//  RivuletTests
//
//  A settings row grows on focus by outsetting its capsule, NOT by scaling the
//  cell. The rows are ~816pt wide and 58pt tall, so a uniform scale is wildly
//  anisotropic in effect: the 1.04 this replaced grew the capsule 16.3pt per
//  side horizontally and 1.3pt vertically, which reads as a sideways stretch.
//
//  Growth is geometry, so it gets measured rather than eyeballed: the focused
//  capsule must equal the resting one outset by the same amount on all four
//  sides, and must stay inside the row pitch so it never collides with the
//  neighbouring row's capsule.
//

import XCTest
import UIKit
@testable import Rivulet

@MainActor
final class SettingsCellFocusGrowthTests: XCTestCase {

    /// The real row box: right pane is 45% of 1920 less the section's 24pt side
    /// insets, at the layout's fixed 72pt row height.
    private let rowFrame = CGRect(x: 0, y: 0, width: 1920 * 0.45 - 48, height: 72)
    /// Vertical distance between two rows' capsules: 3pt resting inset, 8pt
    /// interGroupSpacing, 3pt again.
    private let capsuleGap: CGFloat = 14

    /// Lays out a row and returns its capsule's frame. Applies the appearance
    /// directly: `isFocused` belongs to the focus engine, and a bare
    /// `UIFocusAnimationCoordinator` never runs its block outside a real focus
    /// update, so `didUpdateFocus` is not drivable from a unit test.
    private func capsuleFrame(focused: Bool, cell: SettingsCell = SettingsCell(frame: .zero)) -> CGRect {
        cell.frame = rowFrame
        cell.configure(title: "Hero", value: "On", showsChevron: false, destructive: false)
        cell.applyAppearance(focused: focused)
        cell.layoutIfNeeded()
        guard let capsule = cell.contentView.subviews.first(where: { $0 is CapsuleBackgroundView }) else {
            XCTFail("capsule background missing")
            return .zero
        }
        return capsule.frame
    }

    func test_focusOutsetsCapsuleEquallyOnAllFourSides() {
        let resting = capsuleFrame(focused: false)
        let focused = capsuleFrame(focused: true)

        let left = resting.minX - focused.minX
        let right = focused.maxX - resting.maxX
        let top = resting.minY - focused.minY
        let bottom = focused.maxY - resting.maxY

        XCTAssertGreaterThan(left, 0, "focus should grow the capsule")
        for (edge, grown) in [("right", right), ("top", top), ("bottom", bottom)] {
            XCTAssertEqual(grown, left, accuracy: 0.01, "\(edge) grew \(grown), left grew \(left)")
        }
    }

    /// Guards the tuning knob: an outset past half the gap would have the focused
    /// capsule overlap its neighbour's.
    func test_verticalGrowthStaysInsideTheRowPitch() {
        let resting = capsuleFrame(focused: false)
        let focused = capsuleFrame(focused: true)
        XCTAssertLessThan(focused.maxY - resting.maxY, capsuleGap,
                          "focused capsule reaches into the next row's capsule")
    }

    /// The scale is what made growth anisotropic; the cell must not carry one.
    func test_focusDoesNotScaleTheCell() {
        let cell = SettingsCell(frame: .zero)
        _ = capsuleFrame(focused: true, cell: cell)
        XCTAssertEqual(cell.transform, .identity)
    }

    /// The grown capsule leaves the cell's bounds, so it has to draw above the
    /// rows either side of it.
    func test_focusedCellLiftsAboveItsNeighbours() {
        let resting = SettingsCell(frame: .zero)
        let focused = SettingsCell(frame: .zero)
        _ = capsuleFrame(focused: false, cell: resting)
        _ = capsuleFrame(focused: true, cell: focused)
        XCTAssertGreaterThan(focused.layer.zPosition, resting.layer.zPosition)
    }
}
