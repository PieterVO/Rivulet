// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AetherAdvancedStatsTests.swift
//  RivuletTests
//
//  Pure tests for the app-side telemetry snapshot the Info popup's Advanced
//  tab consumes. No engine needed: the struct is constructed directly.
//

import XCTest
@testable import Rivulet

final class AetherAdvancedStatsTests: XCTestCase {

    func testIsEmptyWhenEveryFieldNil() {
        XCTAssertTrue(AetherAdvancedStats().isEmpty)
    }

    func testNotEmptyWhenOnlyDecoderLabelPresent() {
        XCTAssertFalse(AetherAdvancedStats(backend: "VideoToolbox HEVC (HW)").isEmpty)
    }

    func testNotEmptyWhenOnlyTelemetryFieldPresent() {
        XCTAssertFalse(AetherAdvancedStats(instantBitrateMbps: 24.5).isEmpty)
    }

    func testNotEmptyWhenOnlyEngineCounterPresent() {
        XCTAssertFalse(AetherAdvancedStats(rssMb: 812).isEmpty)
    }
}
