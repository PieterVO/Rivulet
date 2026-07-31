// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DirectionalInputBindingTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class DirectionalInputBindingTests: XCTestCase {

    private func recognizers<T: UIGestureRecognizer>(_ type: T.Type, on view: UIView) -> [T] {
        (view.gestureRecognizers ?? []).compactMap { $0 as? T }
    }

    // MARK: Installation — both transports, always together

    func test_installsPressTapAndIndirectSwipe_perDirection() {
        let view = UIView()
        let binding = DirectionalInputBinding(view: view, directions: [.up, .down], onTap: { _ in })

        let taps = recognizers(UITapGestureRecognizer.self, on: view)
        let swipes = recognizers(UISwipeGestureRecognizer.self, on: view)
        XCTAssertEqual(taps.count, 2)
        XCTAssertEqual(swipes.count, 2)

        let upTap = taps.first { binding.direction(of: $0) == .up }
        XCTAssertEqual(upTap?.allowedPressTypes, [NSNumber(value: UIPress.PressType.upArrow.rawValue)])

        let upSwipe = swipes.first { binding.direction(of: $0) == .up }
        XCTAssertEqual(upSwipe?.direction, .up)
        XCTAssertEqual(upSwipe?.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.indirect.rawValue)])
        // A tvOS swipe recognizer with default press types waits on a
        // .select press; the binding must clear them.
        XCTAssertEqual(upSwipe?.allowedPressTypes, [])
    }

    func test_holdDirections_getLongPressAtHoldThreshold() {
        let view = UIView()
        let binding = DirectionalInputBinding(
            view: view, directions: [.left, .right], holds: [.left], onTap: { _ in }, onHold: { _ in }
        )

        let longs = recognizers(UILongPressGestureRecognizer.self, on: view)
        XCTAssertEqual(longs.count, 1)
        XCTAssertEqual(binding.direction(of: longs[0]), .left)
        XCTAssertEqual(longs[0].minimumPressDuration, InputConfig.holdThreshold, accuracy: 0.001)
        XCTAssertEqual(longs[0].allowedPressTypes, [NSNumber(value: UIPress.PressType.leftArrow.rawValue)])
    }

    // MARK: Callback funnel — press and swipe reach the same tap callback

    func test_pressTapAndSwipe_fireSameCallbackWithDirection() {
        let view = UIView()
        var fired: [DirectionalInputBinding.Direction] = []
        let binding = DirectionalInputBinding(view: view, directions: [.left, .right], onTap: { fired.append($0) })

        let rightTap = recognizers(UITapGestureRecognizer.self, on: view).first { binding.direction(of: $0) == .right }!
        let leftSwipe = recognizers(UISwipeGestureRecognizer.self, on: view).first { binding.direction(of: $0) == .left }!

        binding.handleTap(rightTap)
        binding.handleSwipe(leftSwipe)
        XCTAssertEqual(fired, [.right, .left])
    }

    func test_hold_firesOnlyOnBegan() {
        let view = UIView()
        var holds: [DirectionalInputBinding.Direction] = []
        let binding = DirectionalInputBinding(
            view: view, directions: [.right], holds: [.right], onTap: { _ in }, onHold: { holds.append($0) }
        )

        let long = recognizers(UILongPressGestureRecognizer.self, on: view)[0]
        binding.handleLong(long)  // state .possible — must not fire
        XCTAssertTrue(holds.isEmpty)
        long.state = .began
        binding.handleLong(long)
        XCTAssertEqual(holds, [.right])
    }

    func test_foreignRecognizer_hasNoDirectionAndFiresNothing() {
        let view = UIView()
        var fired = 0
        let binding = DirectionalInputBinding(view: view, directions: [.up], onTap: { _ in fired += 1 })

        let foreign = UITapGestureRecognizer()
        XCTAssertNil(binding.direction(of: foreign))
        binding.handleTap(foreign)
        XCTAssertEqual(fired, 0)
    }
}
