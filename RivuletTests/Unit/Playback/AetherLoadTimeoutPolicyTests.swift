// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AetherLoadTimeoutPolicyTests.swift
//  RivuletTests
//
//  Issue #245: TrueHD 7.1 and DTS-HD MA 7.1 titles could stick on the loading
//  spinner forever because the host awaited the engine's load bare. The fix
//  races that load against a deadline and lets the existing HLS fallback
//  recover. The single most load-bearing property of the fix is that the
//  deadline error is NOT seen as a cancellation, because the catch that drives
//  the fallback returns early for cancellations. If that ever regresses the
//  fallback is silently skipped and the hang comes back with no other symptom.
//
//  Pure tests: no engine, no view model.
//

import XCTest
@testable import Rivulet

final class AetherLoadTimeoutPolicyTests: XCTestCase {

    // MARK: - The deadline error must reach the fallback

    /// The whole fix depends on this. `startWithFallback`'s catch runs
    /// `if isCancellationError(error) || Task.isCancelled { return }` before it
    /// reaches the fallback, so a timeout classified as a cancellation would be
    /// swallowed and nothing would change.
    func testTimedOutIsNotClassifiedAsCancellation() {
        let error = AetherLoadTimeoutPolicy.TimedOut(seconds: 60)
        XCTAssertFalse(
            isCancellationError(error),
            "A deadline expiry is a real startup failure and must reach the HLS fallback"
        )
    }

    /// `isCancellationError` bridges through NSError, so pin the properties it
    /// actually checks rather than only the aggregate result. The error is
    /// examined as an `Error` existential because that is how it reaches the
    /// catch, and a direct `is CancellationError` test on the concrete type is
    /// rejected at compile time as an impossible cast.
    func testTimedOutBridgesToAForeignDomain() {
        let error: Error = AetherLoadTimeoutPolicy.TimedOut(seconds: 60)
        XCTAssertFalse(error is CancellationError)
        let nsError = error as NSError
        XCTAssertNotEqual(nsError.domain, NSURLErrorDomain)
        XCTAssertNotEqual(nsError.domain, NSCocoaErrorDomain)
    }

    /// The sleep child throws `CancellationError` when the load wins the race.
    /// That error is discarded with the group, but if it ever did escape it
    /// would correctly read as a cancellation and not as a timeout.
    func testLoserCancellationRemainsACancellation() {
        XCTAssertTrue(isCancellationError(CancellationError()))
    }

    // MARK: - Reason string

    /// A hang and a thrown startup error must not merge into one Sentry issue.
    func testFallbackReasonIsDistinctFromTheThrownFailureReason() {
        XCTAssertEqual(AetherLoadTimeoutPolicy.fallbackReason, "aether_startup_timeout")
        XCTAssertNotEqual(AetherLoadTimeoutPolicy.fallbackReason, "aether_startup_load_failed")
    }

    /// No stream URL may ever appear in the error text: Plex URLs carry account
    /// tokens and IPTV paths embed credentials.
    func testTimedOutDescriptionCarriesNoURL() {
        let description = AetherLoadTimeoutPolicy.TimedOut(seconds: 60).description
        XCTAssertFalse(description.contains("http"))
        XCTAssertFalse(description.lowercased().contains("x-plex-token"))
        XCTAssertTrue(description.contains("60"))
    }

    // MARK: - Deadline value

    /// Generous on purpose. The failure being bounded is an indefinite hang, so
    /// under-waiting cuts off slow-but-healthy 4K starts, which is the worse
    /// error. The upper bound exists because the fallback then runs its own
    /// multi-poll HLS preflight on top of this wait.
    func testDeadlineIsGenerousButBounded() {
        XCTAssertGreaterThanOrEqual(AetherLoadTimeoutPolicy.startupLoadDeadline, 45)
        XCTAssertLessThanOrEqual(AetherLoadTimeoutPolicy.startupLoadDeadline, 90)
    }

    // MARK: - Audio delivery honesty (the INFO sheet)

    /// These are the codecs behind #245. The engine cannot stream-copy them, so
    /// it re-encodes to FLAC on-device. That is not bit-exact Direct Play, but
    /// it is also not a server transcode, which is what the sheet used to imply.
    func testTrueHDAndDTSAreReencoded() {
        XCTAssertTrue(AetherAudioDelivery.isReencoded(codec: "truehd"))
        XCTAssertTrue(AetherAudioDelivery.isReencoded(codec: "dca"))
        XCTAssertTrue(AetherAudioDelivery.isReencoded(codec: "dts"))
        XCTAssertTrue(AetherAudioDelivery.isReencoded(codec: "mp3"))
        XCTAssertTrue(AetherAudioDelivery.isReencoded(codec: "opus"))
    }

    func testStreamCopiedCodecsAreNotReencoded() {
        XCTAssertFalse(AetherAudioDelivery.isReencoded(codec: "aac"))
        XCTAssertFalse(AetherAudioDelivery.isReencoded(codec: "ac3"))
        XCTAssertFalse(AetherAudioDelivery.isReencoded(codec: "eac3"))
        XCTAssertFalse(AetherAudioDelivery.isReencoded(codec: "ec3"))
    }

    /// Codec strings arrive from Plex metadata in mixed case and occasionally
    /// hyphenated, matching how ContentRouter normalises video codecs.
    func testCodecMatchingIsCaseAndSeparatorInsensitive() {
        XCTAssertFalse(AetherAudioDelivery.isReencoded(codec: "EAC3"))
        XCTAssertFalse(AetherAudioDelivery.isReencoded(codec: "E-AC3"))
        XCTAssertTrue(AetherAudioDelivery.isReencoded(codec: "TrueHD"))
    }

    /// Unknown codec is better described as untouched than as re-encoded: the
    /// sheet should not invent a downgrade it cannot substantiate.
    func testMissingCodecIsNotReportedAsReencoded() {
        XCTAssertFalse(AetherAudioDelivery.isReencoded(codec: nil))
        XCTAssertFalse(AetherAudioDelivery.isReencoded(codec: ""))
    }
}
