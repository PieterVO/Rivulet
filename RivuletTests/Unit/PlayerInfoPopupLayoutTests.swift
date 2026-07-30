// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerInfoPopupLayoutTests.swift
//  RivuletTests
//
//  Measurements for the Info popup, not assertions about intent: the pill row's
//  horizontal focus rule, the Description tab's vertical centering (an Auto
//  Layout claim — spacers that must collapse when the summary grows), and the
//  monospaced digits the Advanced tab's 1 Hz values depend on.
//

import XCTest
@testable import Rivulet

@MainActor
final class PlayerInfoPopupLayoutTests: XCTestCase {

    // MARK: - Pill row: horizontal focus stops at the ends

    func testHorizontalMoveAllowedOnlyToAdjacentPill() {
        // Description(0) | Info(1) | Advanced(2)
        XCTAssertTrue(PillTabBarView.allowsHorizontalMove(from: 0, to: 1, movingLeft: false, pillCount: 3))
        XCTAssertTrue(PillTabBarView.allowsHorizontalMove(from: 2, to: 1, movingLeft: true, pillCount: 3))
    }

    func testLeftOnFirstPillIsRefused() {
        // The reported bug: Left on Description jumped to Advanced.
        XCTAssertFalse(PillTabBarView.allowsHorizontalMove(from: 0, to: 2, movingLeft: true, pillCount: 3))
        // And with no candidate at all it still must not move.
        XCTAssertFalse(PillTabBarView.allowsHorizontalMove(from: 0, to: nil, movingLeft: true, pillCount: 3))
    }

    func testRightOnLastPillIsRefused() {
        XCTAssertFalse(PillTabBarView.allowsHorizontalMove(from: 2, to: nil, movingLeft: false, pillCount: 3))
        XCTAssertFalse(PillTabBarView.allowsHorizontalMove(from: 2, to: 0, movingLeft: false, pillCount: 3))
    }

    func testMoveOffTheBarIsRefused() {
        // nil landing = the engine offered a view outside the bar.
        XCTAssertFalse(PillTabBarView.allowsHorizontalMove(from: 1, to: nil, movingLeft: false, pillCount: 3))
    }

    // MARK: - Description tab: title on top, summary centered below it

    private func descriptionView(summary: String) -> CardDescriptionView {
        var episode = PlexMetadata()
        episode.type = "episode"
        episode.title = "The Pilot"
        episode.grandparentTitle = "Some Show"
        episode.parentIndex = 1
        episode.index = 1
        episode.summary = summary
        let view = CardDescriptionView(metadata: episode)
        // The Info popup's real content area: 560 panel - 2*20 padding
        // - 2*8 pill inset wide, 520 - (56 bar + 16 spacing) tall.
        view.frame = CGRect(x: 0, y: 0, width: 504, height: 448)
        view.layoutIfNeeded()
        return view
    }

    private func label(withText text: String, in view: UIView) -> UILabel? {
        for subview in view.subviews {
            if let label = subview as? UILabel, label.text == text { return label }
            if let found = self.label(withText: text, in: subview) { return found }
        }
        return nil
    }

    func testShortSummaryIsVerticallyCenteredUnderTheTitle() throws {
        let summary = "A short summary."
        let view = descriptionView(summary: summary)
        let title = try XCTUnwrap(label(withText: "The Pilot", in: view))
        let body = try XCTUnwrap(label(withText: summary, in: view))

        let titleFrame = title.convert(title.bounds, to: view)
        let bodyFrame = body.convert(body.bounds, to: view)
        let gapAbove = bodyFrame.minY - titleFrame.maxY
        let gapBelow = view.bounds.height - bodyFrame.maxY

        XCTAssertGreaterThan(gapAbove, 40, "summary should not be hugging the title")
        XCTAssertEqual(gapAbove, gapBelow, accuracy: 14,
                       "summary should sit midway between the title and the sheet's bottom")
    }

    func testLongSummaryCollapsesTheSpacersAndStartsBelowTheTitle() throws {
        // Enough paragraphs to overflow 448pt, so centering must give way to
        // scrolling from the top.
        let paragraphs = (1...12).map { "Paragraph number \($0) of a very long summary that wraps onto more than one line on its own." }
        let view = descriptionView(summary: paragraphs.joined(separator: "\n"))
        let title = try XCTUnwrap(label(withText: "The Pilot", in: view))
        let first = try XCTUnwrap(label(withText: paragraphs[0], in: view))

        let titleFrame = title.convert(title.bounds, to: view)
        let firstFrame = first.convert(first.bounds, to: view)

        XCTAssertLessThan(firstFrame.minY - titleFrame.maxY, 30,
                          "spacers must collapse once the summary overflows the sheet")
    }

    // MARK: - Advanced tab: values must not reflow as they tick

    func testInfoRowValueUsesMonospacedDigits() throws {
        let text = PlayerInfoSheetStyle.infoRowText("Bitrate", "12.3 Mbps")
        let valueFont = try XCTUnwrap(
            text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(valueFont, UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .regular))
    }

    func testDigitWidthIsStableAcrossValues() {
        // The actual property that matters: a counter changing digits must not
        // change the string's width.
        let font = UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .regular)
        let width: (String) -> CGFloat = { ($0 as NSString).size(withAttributes: [.font: font]).width }
        XCTAssertEqual(width("111 MB"), width("888 MB"), accuracy: 0.5)
    }
}
