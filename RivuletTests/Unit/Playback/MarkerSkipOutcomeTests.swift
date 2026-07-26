// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MarkerSkipOutcomeTests.swift
//  RivuletTests
//
//  Pure-logic tests for MarkerSkipPolicy: whether pressing a skip pill
//  seeks or finishes playback. Issue #231 — "Skip Credits" seeked to the
//  last frame and parked there forever because AetherEngine converts a
//  seek landing inside its end-of-media epsilon into `.paused` and
//  withholds the terminal `.ended`.
//

import XCTest
@testable import Rivulet

final class MarkerSkipOutcomeTests: XCTestCase {

    // MARK: - Credits at the media end finish

    func testCreditsEndingAtDurationFinishes() {
        let outcome = MarkerSkipPolicy.outcome(
            isCredits: true,
            markerEnd: 1800,
            duration: 1800
        )

        XCTAssertEqual(outcome, .finish)
    }

    func testCreditsEndingPastDurationFinishes() {
        // Plex occasionally reports a marker end slightly beyond the
        // container duration.
        let outcome = MarkerSkipPolicy.outcome(
            isCredits: true,
            markerEnd: 1801.4,
            duration: 1800
        )

        XCTAssertEqual(outcome, .finish)
    }

    func testCreditsEndingJustShortOfDurationFinishes() {
        // Inside the 1.0s tolerance: not watchable content, still a finish.
        let outcome = MarkerSkipPolicy.outcome(
            isCredits: true,
            markerEnd: 1799.4,
            duration: 1800
        )

        XCTAssertEqual(outcome, .finish)
    }

    func testCreditsAtToleranceBoundaryFinishes() {
        let outcome = MarkerSkipPolicy.outcome(
            isCredits: true,
            markerEnd: 1800 - MarkerSkipPolicy.finishToleranceSeconds,
            duration: 1800
        )

        XCTAssertEqual(outcome, .finish)
    }

    // MARK: - Mid-stream markers still seek

    func testMidStreamCreditsStingerSeeks() {
        // A credits marker that ends well before the file end (post-credits
        // scene follows) must keep seeking, not end the episode.
        let outcome = MarkerSkipPolicy.outcome(
            isCredits: true,
            markerEnd: 1700,
            duration: 1800
        )

        XCTAssertEqual(outcome, .seek(target: 1700))
    }

    func testIntroSeeksToMarkerEnd() {
        let outcome = MarkerSkipPolicy.outcome(
            isCredits: false,
            markerEnd: 95,
            duration: 1800
        )

        XCTAssertEqual(outcome, .seek(target: 95))
    }

    func testRecapSeeksToMarkerEnd() {
        let outcome = MarkerSkipPolicy.outcome(
            isCredits: false,
            markerEnd: 42.5,
            duration: 1800
        )

        XCTAssertEqual(outcome, .seek(target: 42.5))
    }

    func testNonCreditsMarkerAtMediaEndStillSeeks() {
        // Only credits get the finish treatment; an ad marker running to the
        // end is clamped inside the media exactly as before.
        let outcome = MarkerSkipPolicy.outcome(
            isCredits: false,
            markerEnd: 1800,
            duration: 1800
        )

        XCTAssertEqual(outcome, .seek(target: 1800 - MarkerSkipPolicy.seekEpsilonSeconds))
    }

    // MARK: - Clamping and degenerate inputs

    func testSeekTargetIsClampedInsideMedia() {
        let outcome = MarkerSkipPolicy.outcome(
            isCredits: false,
            markerEnd: 5000,
            duration: 1800
        )

        XCTAssertEqual(outcome, .seek(target: 1799.5))
    }

    func testNegativeMarkerEndClampsToZero() {
        let outcome = MarkerSkipPolicy.outcome(
            isCredits: false,
            markerEnd: -10,
            duration: 1800
        )

        XCTAssertEqual(outcome, .seek(target: 0))
    }

    func testUnknownDurationAlwaysSeeks() {
        // Duration 0 (live, or metadata not settled): never finish on a
        // guess — fall back to the plain seek to the marker end.
        XCTAssertEqual(
            MarkerSkipPolicy.outcome(isCredits: true, markerEnd: 1800, duration: 0),
            .seek(target: 1800)
        )
        XCTAssertEqual(
            MarkerSkipPolicy.outcome(isCredits: false, markerEnd: 95, duration: 0),
            .seek(target: 95)
        )
    }

    func testUnknownDurationClampsNegativeMarkerEnd() {
        XCTAssertEqual(
            MarkerSkipPolicy.outcome(isCredits: true, markerEnd: -5, duration: 0),
            .seek(target: 0)
        )
    }
}
