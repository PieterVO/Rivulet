// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InfoSectionRevealTests.swift
//  RivuletTests
//
//  The Info popup's sheets scroll by revealing the focused section
//  (`InfoScrollView.revealOffsetY`): minimal movement when the section fits
//  the viewport, top/bottom alignment when it doesn't, always clamped to the
//  scrollable range. Pure math, so the focus-driven behavior that can only be
//  exercised on a device/simulator rests on a verified core.
//

import XCTest
@testable import Rivulet

final class InfoSectionRevealTests: XCTestCase {

    /// Padding baked into the reveal target so a focused section never sits
    /// flush against the clip edge. Mirrors `InfoScrollView.revealPadding`.
    private let pad: CGFloat = 12

    private func reveal(
        current: CGFloat,
        section: (minY: CGFloat, maxY: CGFloat),
        viewport: CGFloat,
        content: CGFloat
    ) -> CGFloat {
        InfoScrollView.revealOffsetY(
            current: current,
            sectionMinY: section.minY,
            sectionMaxY: section.maxY,
            viewportHeight: viewport,
            contentHeight: content
        )
    }

    func testFullyVisibleSectionDoesNotScroll() {
        // Section sits comfortably inside the viewport — offset unchanged, so
        // entering the sheet from the tab bar never jumps the leading title.
        XCTAssertEqual(reveal(current: 0, section: (40, 200), viewport: 400, content: 800), 0)
    }

    func testSectionBelowViewportScrollsMinimally() {
        // Bottom-aligns the padded section: (700 + 12) - 400 = 312.
        XCTAssertEqual(reveal(current: 0, section: (500, 700), viewport: 400, content: 800), 312)
    }

    func testSectionAboveViewportScrollsToItsPaddedTop() {
        // Top-aligns the padded section: 40 - 12 = 28.
        XCTAssertEqual(reveal(current: 400, section: (40, 200), viewport: 400, content: 800), 28)
    }

    func testTargetClampsToTop() {
        // Padded top would be negative — clamps to 0.
        XCTAssertEqual(reveal(current: 100, section: (0, 200), viewport: 400, content: 800), 0)
    }

    func testTargetClampsToMaxOffset() {
        // Content 600 in a 400 viewport → max offset 200; padded bottom-align
        // would be 202.
        XCTAssertEqual(reveal(current: 0, section: (450, 590), viewport: 400, content: 600), 200)
    }

    func testTallSectionEnteredFromAboveAlignsTop() {
        // Section taller than the viewport, focus arriving from above — show
        // its beginning: 100 - 12 = 88.
        XCTAssertEqual(reveal(current: 0, section: (100, 700), viewport: 400, content: 800), 88)
    }

    func testTallSectionEnteredFromBelowAlignsBottom() {
        // Same tall section, focus returning from below — keep the reading
        // position by showing its end: (700 + 12) - 400 = 312.
        XCTAssertEqual(reveal(current: 500, section: (100, 700), viewport: 400, content: 800), 312)
    }

    func testContentShorterThanViewportNeverScrolls() {
        XCTAssertEqual(reveal(current: 0, section: (40, 200), viewport: 400, content: 300), 0)
    }

    // MARK: - Declined-press stepping (`steppedOffsetY`)
    //
    // The reveal math above can only reach content a section wrapper covers.
    // A section taller than the panel has no focus target in its lower half,
    // so an arrow press the engine declines steps the offset instead (#242).

    private func step(
        current: CGFloat,
        delta: CGFloat,
        viewport: CGFloat,
        content: CGFloat
    ) -> CGFloat {
        InfoScrollView.steppedOffsetY(
            current: current,
            delta: delta,
            viewportHeight: viewport,
            contentHeight: content
        )
    }

    func testStepDownMovesByDelta() {
        XCTAssertEqual(step(current: 0, delta: 240, viewport: 400, content: 1200), 240)
    }

    func testStepUpMovesByDelta() {
        XCTAssertEqual(step(current: 240, delta: -240, viewport: 400, content: 1200), 0)
    }

    func testStepDownClampsToMaxOffset() {
        // Content 1200 in a 400 viewport → max offset 800.
        XCTAssertEqual(step(current: 700, delta: 240, viewport: 400, content: 1200), 800)
    }

    func testStepUpClampsToTop() {
        XCTAssertEqual(step(current: 100, delta: -240, viewport: 400, content: 1200), 0)
    }

    func testStepIsANoOpWhenContentFitsViewport() {
        // Nothing to scroll — the press should leave the offset alone so it
        // can bubble instead of silently swallowing a focus move.
        XCTAssertEqual(step(current: 0, delta: 240, viewport: 400, content: 300), 0)
    }

    func testStepThroughSectionTallerThanViewport() {
        // The exact #242 shape: one 900pt section in a 560pt panel. Three
        // downward steps walk the offset to the bottom of the content.
        var offset: CGFloat = 0
        for _ in 0..<3 {
            offset = step(current: offset, delta: 240, viewport: 560, content: 900)
        }
        XCTAssertEqual(offset, 340)
    }
}
