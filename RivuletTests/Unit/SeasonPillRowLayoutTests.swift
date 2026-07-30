// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SeasonPillRowLayoutTests.swift
//  RivuletTests
//
//  The season pill row lives in a scroller so a show with more seasons than fit
//  the screen can still reach them all (#261). Whether it actually scrolls comes
//  down to one Auto Layout question that can't be eyeballed: does the row keep
//  its natural width and overflow (scrollable), or does it get compressed to fit
//  (nothing to scroll, labels truncated)?
//
//  Regression: the scroller's hug constraint sat at .defaultHigh, tying with the
//  pill labels' compression resistance. The solver squeezed the pills instead of
//  overflowing, so contentSize == bounds and the row never scrolled.
//

import XCTest
import UIKit
@testable import Rivulet

@MainActor
final class SeasonPillRowLayoutTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    /// The scroller holding the pills — the one whose subtree has a pill in it
    /// (the below-fold collection is a scroll view too).
    private func pillScroller(in root: UIView) -> UIScrollView? {
        var stack: [UIView] = [root]
        while let v = stack.popLast() {
            if let scroll = v as? UIScrollView, contains(SeasonPillView.self, in: scroll) { return scroll }
            stack.append(contentsOf: v.subviews)
        }
        return nil
    }

    private func contains(_ type: AnyClass, in root: UIView) -> Bool {
        var stack = root.subviews
        while let v = stack.popLast() {
            if v.isKind(of: type) { return true }
            stack.append(contentsOf: v.subviews)
        }
        return false
    }

    private func makeView(seasons: Int) -> ExpandedDetailContainerView {
        let view = ExpandedDetailContainerView(frame: screen)
        view.setSeasonPills(
            (1...seasons).map { "Season \($0)" },
            seasonRefIDs: (1...seasons).map(String.init),
            selectedIndex: 0
        )
        view.layoutIfNeeded()
        return view
    }

    /// The bug in #261: 14 seasons don't fit, so the row MUST overflow its window
    /// rather than compress into it. Without overflow there is nothing for the
    /// focus engine to scroll and the later seasons are unreachable.
    func testManySeasonsOverflowTheScrollerSoItCanScroll() throws {
        let view = makeView(seasons: 14)
        let scroll = try XCTUnwrap(pillScroller(in: view))
        XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width)
    }

    /// The scroller's window is capped at the screen (it used to run off it).
    func testScrollerWindowStaysOnScreen() throws {
        let view = makeView(seasons: 14)
        let scroll = try XCTUnwrap(pillScroller(in: view))
        XCTAssertLessThanOrEqual(scroll.convert(scroll.bounds, to: view).maxX, screen.width)
    }

    /// The other direction: a short row still hugs its pills instead of
    /// stretching the header to the full screen width.
    func testFewSeasonsHugTheRow() throws {
        let view = makeView(seasons: 3)
        let scroll = try XCTUnwrap(pillScroller(in: view))
        XCTAssertEqual(scroll.contentSize.width, scroll.bounds.width, accuracy: 0.5)
        XCTAssertLessThan(scroll.bounds.width, screen.width / 2)
    }
}
