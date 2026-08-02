// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InfoSheetOverflowTests.swift
//  RivuletTests
//
//  The Info popup's sheets self-size to short content via a scrollView-height
//  == content-height constraint. Its priority must sit BELOW the content's own
//  vertical compression resistance (`.defaultHigh` for a UILabel). AT
//  `.defaultHigh` the two tie, and the solver resolves the tie by squashing the
//  content to the viewport rather than breaking the constraint. `contentSize`
//  then reports the squashed height, so `InfoScrollView.needsFocusableRows` is
//  false, every `InfoFocusRowView` is unfocusable, and the Down crossing from
//  the pills into the sheet is dead — while part of the sheet is off screen.
//
//  Device measurement that produced this: `content=448 bounds=448
//  needsRows=false rows=0/11 offsetY=0 insetTop=0 stackY=0 stackH=448
//  naturalH=468`.
//
//  The host geometry below matters and an earlier version of this test got it
//  wrong: the panel CAPS its height (`heightAnchor <= maxHeight`), it does not
//  FIX it. Pinning the sheet to a fixed-height host removes the competition
//  entirely and the test passes either way, proving nothing.
//

import XCTest
import UIKit
@testable import Rivulet

final class InfoSheetOverflowTests: XCTestCase {

    /// The real viewport: `PlayerRailPanelView`'s 560pt cap less 20pt padding
    /// top and bottom, the 56pt pill bar and the 16pt gap under it.
    private let cappedHeight: CGFloat = 448
    private let sheetWidth: CGFloat = 480

    /// Enough present fields to push the sheet past the cap, which is the only
    /// condition under which the bug exists. A partial set measured 372pt here,
    /// under the 448 cap, so the sheet hugged it and there was nothing to
    /// overflow — the first version of this fixture proved nothing for exactly
    /// that reason. The device capture that found the bug sat at 468pt.
    private func sessionStats() -> AetherAdvancedStats {
        AetherAdvancedStats(
            backend: "VideoToolbox (HEVC)",
            audioBridge: "EAC3 JOC passthrough",
            instantBitrateMbps: 24.5,
            averageBitrateMbps: 21.2,
            audioBridgeBitrateMbps: 0.76,
            observedFps: 23.976,
            droppedFrameCount: 0,
            forwardBufferSeconds: 6.5,
            cachedBytes: 41_235_456,
            networkThroughputMbps: 88.1,
            networkTransferredBytes: 512_998_144,
            avSyncGapMs: 3.5,
            producerRestartCount: 1,
            muxedBytesLifetime: 498_123_456,
            serverBytesSentLifetime: 501_224_448,
            serverRequestCount: 142,
            demuxerBytesFetched: 530_112_000,
            audioBridgeLiveBytes: 98_304,
            rssMb: 412
        )
    }

    /// Mirrors the popup: the sheet fills its host, and the host is CAPPED, not
    /// fixed. The sheet's own self-sizing constraint is what drives the height
    /// until the cap binds.
    private func layOutCapped(_ sheet: UIView) {
        let outer = UIView(frame: CGRect(x: 0, y: 0, width: sheetWidth, height: 2000))
        let host = UIView()
        [sheet, host].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        host.addSubview(sheet)
        outer.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: outer.topAnchor),
            host.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            host.widthAnchor.constraint(equalToConstant: sheetWidth),
            host.heightAnchor.constraint(lessThanOrEqualToConstant: cappedHeight),

            sheet.topAnchor.constraint(equalTo: host.topAnchor),
            sheet.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            sheet.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        outer.layoutIfNeeded()
    }

    /// The regression. Content taller than the cap must keep its real height so
    /// the sheet reports overflow and hands out focusable rows.
    func testContentTallerThanTheCapIsNotSquashedToTheViewport() {
        let stats = sessionStats()
        let sheet = CardStatsView(provider: { stats })
        sheet.setActive(true)
        layOutCapped(sheet)

        let scroll = sheet.infoScrollView
        guard let content = scroll.subviews.first else {
            return XCTFail("the sheet put no content view in its scroll view")
        }
        let natural = content.systemLayoutSizeFitting(
            CGSize(width: content.bounds.width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height

        XCTAssertGreaterThan(natural, scroll.bounds.height,
                             "fixture must overflow the cap or the test proves nothing")
        XCTAssertEqual(content.frame.height, natural, accuracy: 0.5,
                       "content was squashed to the viewport — the self-sizing constraint is "
                       + "tying with the content's compression resistance instead of breaking")
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height,
                             "a squashed sheet reports contentSize == bounds and looks like it fits")
        XCTAssertTrue(scroll.needsFocusableRows,
                      "an overflowing sheet must make its rows focusable, or Down into it is dead")
    }

    /// The behaviour the priority exists for must survive: with room to spare
    /// the sheet still hugs its content instead of stretching to the cap.
    func testShortContentStillHugsInsteadOfStretchingToTheCap() {
        let sheet = CardStatsView(provider: { AetherAdvancedStats() })
        sheet.setActive(true)
        layOutCapped(sheet)

        XCTAssertLessThan(sheet.bounds.height, cappedHeight,
                          "an empty sheet must not stretch to the full cap")
    }
}
