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

    /// The window is edge to edge (it used to run off the screen entirely), so
    /// pills bleed off the real edges like the episode rows. The content edge is
    /// a pad inside the scroller: the first pill rests on the shared content
    /// line, which is where the episode thumb below it starts.
    func testWindowIsFullBleedAndFirstPillRestsOnTheContentEdge() throws {
        let view = makeView(seasons: 14)
        let scroll = try XCTUnwrap(pillScroller(in: view))
        let window = scroll.convert(scroll.bounds, to: view)
        XCTAssertEqual(window.minX, 0, accuracy: 0.5)
        XCTAssertEqual(window.maxX, screen.width, accuracy: 0.5)
        let first = try XCTUnwrap(allPills(in: scroll).first)
        XCTAssertEqual(
            first.convert(first.bounds, to: view).minX,
            PreviewCarouselGeometry.expandedChromeInset,
            accuracy: 0.5
        )
    }

    /// Opening on a late season must scroll it in, along with BOTH neighbours —
    /// the focus engine picks the next Left/Right target from what is on-window,
    /// so an off-window neighbour is what lets a sideways press escape into the
    /// episodes.
    func testOpeningOnALateSeasonRevealsItAndItsNeighbours() throws {
        let view = ExpandedDetailContainerView(frame: screen)
        view.setSeasonPills(
            (1...14).map { "Season \($0)" },
            seasonRefIDs: (1...14).map(String.init),
            selectedIndex: 12                      // Season 13, well past the window
        )
        view.layoutIfNeeded()
        let scroll = try XCTUnwrap(pillScroller(in: view))
        let pills = allPills(in: scroll)
        XCTAssertEqual(pills.count, 14)
        let window = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)
        for i in 11...13 {
            let frame = scroll.convert(pills[i].bounds, from: pills[i])
            XCTAssertTrue(window.contains(frame), "pill \(i) is off-window: \(frame) vs \(window)")
        }
    }

    /// Landing on the LAST season must leave the content margin, not park the
    /// pill against the screen edge where its focus scale gets clipped.
    func testLandingOnTheLastSeasonKeepsTheContentMargin() throws {
        let view = ExpandedDetailContainerView(frame: screen)
        view.setSeasonPills(
            (1...14).map { "Season \($0)" },
            seasonRefIDs: (1...14).map(String.init),
            selectedIndex: 13
        )
        view.layoutIfNeeded()
        let scroll = try XCTUnwrap(pillScroller(in: view))
        let last = try XCTUnwrap(allPills(in: scroll).last)
        let onScreen = last.convert(last.bounds, to: view)
        let inset = PreviewCarouselGeometry.expandedChromeInset
        XCTAssertEqual(onScreen.maxX, screen.width - inset, accuracy: 0.5)
        // …and the 1.05 focus scale still clears the edge.
        XCTAssertLessThan(onScreen.maxX + onScreen.width * 0.05, screen.width)
    }

    /// In row order, so `allPills[i]` is season i+1.
    private func allPills(in scroll: UIScrollView) -> [SeasonPillView] {
        var stack = scroll.subviews
        var found: [SeasonPillView] = []
        while let v = stack.popLast() {
            if let row = v as? UIStackView {
                found = row.arrangedSubviews.compactMap { $0 as? SeasonPillView }
                break
            }
            stack.append(contentsOf: v.subviews)
        }
        return found
    }

    /// The other direction: a short row fits, so it must not become scrollable.
    func testFewSeasonsDoNotScroll() throws {
        let view = makeView(seasons: 3)
        let scroll = try XCTUnwrap(pillScroller(in: view))
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width)
    }
}
