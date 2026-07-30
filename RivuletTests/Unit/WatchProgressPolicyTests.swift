// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class WatchProgressPolicyTests: XCTestCase {
    private let hour: TimeInterval = 3600

    // MARK: - progress

    func testProgressIsNilWithoutPosition() {
        XCTAssertNil(WatchProgressPolicy.progress(offsetSeconds: 0, runtimeSeconds: hour))
    }

    func testProgressIsNilWithoutRuntime() {
        XCTAssertNil(WatchProgressPolicy.progress(offsetSeconds: 600, runtimeSeconds: nil))
        XCTAssertNil(WatchProgressPolicy.progress(offsetSeconds: 600, runtimeSeconds: 0))
    }

    func testProgressIsCappedAtOne() {
        // Plex occasionally reports an offset a little past the duration.
        XCTAssertEqual(WatchProgressPolicy.progress(offsetSeconds: hour + 30, runtimeSeconds: hour), 1.0)
    }

    // MARK: - hasResumePoint, with a runtime

    func testMidwayIsResumable() {
        XCTAssertTrue(WatchProgressPolicy.hasResumePoint(offsetSeconds: hour / 2, runtimeSeconds: hour))
    }

    func testBarelyStartedIsNotResumable() {
        // 1% in: an accidental start, not worth a resume offer.
        XCTAssertFalse(WatchProgressPolicy.hasResumePoint(offsetSeconds: 36, runtimeSeconds: hour))
    }

    func testPastCompletionThresholdIsNotResumable() {
        // 95% in: Plex treats this as finished, so no resume offer.
        XCTAssertFalse(WatchProgressPolicy.hasResumePoint(offsetSeconds: hour * 0.95, runtimeSeconds: hour))
    }

    // A payload that should have carried a duration but didn't must not be
    // guessed into "resumable" — that would revive finished items.
    func testMissingRuntimeIsNotResumable() {
        XCTAssertFalse(WatchProgressPolicy.hasResumePoint(offsetSeconds: 600, runtimeSeconds: nil))
    }

    // MARK: - hasResumePoint, position only

    func testPositionOnlyIgnoresThresholds() {
        XCTAssertTrue(WatchProgressPolicy.hasResumePoint(offsetSeconds: 1))
        XCTAssertFalse(WatchProgressPolicy.hasResumePoint(offsetSeconds: 0))
    }
}
