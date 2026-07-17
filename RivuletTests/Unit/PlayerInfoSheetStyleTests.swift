// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerInfoSheetStyleTests.swift
//  RivuletTests
//
//  Pure formatter tests for the shared info-sheet style used by both the
//  Info tab (CardInfoView) and the Advanced tab (CardStatsView).
//

import XCTest
@testable import Rivulet

final class PlayerInfoSheetStyleTests: XCTestCase {

    // New formatters for the Advanced tab.
    func testMbpsOneDecimal() {
        XCTAssertEqual(PlayerInfoSheetStyle.mbps(12.34), "12.3 Mbps")
    }

    func testFpsRoundsToWhole() {
        XCTAssertEqual(PlayerInfoSheetStyle.fps(59.9), "60 fps")
    }

    func testMillisecondsNegativeKeepsSign() {
        XCTAssertEqual(PlayerInfoSheetStyle.milliseconds(-8.2), "-8 ms")
    }

    func testMillisecondsPositiveShowsPlusSign() {
        XCTAssertEqual(PlayerInfoSheetStyle.milliseconds(3.6), "+4 ms")
    }

    // Moved-from-CardInfoView formatters: guard the move didn't change output.
    func testBitrateFormatsMbps() {
        XCTAssertEqual(PlayerInfoSheetStyle.bitrate(1_500_000), "1.5 Mbps")
    }

    func testBitrateFormatsKbps() {
        XCTAssertEqual(PlayerInfoSheetStyle.bitrate(128_000), "128 kbps")
    }

    func testBufferSecondsClampsNegativeToZero() {
        XCTAssertEqual(PlayerInfoSheetStyle.bufferSeconds(-2), "0s")
    }

    func testBufferSecondsRoundsToWhole() {
        XCTAssertEqual(PlayerInfoSheetStyle.bufferSeconds(3.4), "3s")
    }
}
