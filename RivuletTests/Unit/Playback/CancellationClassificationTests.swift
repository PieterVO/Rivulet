// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CancellationClassificationTests.swift
//  RivuletTests
//
//  RIVULET-19: an ordinary task cancellation (user backs out of the preview
//  carousel, or switches items, while a load is in flight) was being wrapped
//  into PlayerError.loadFailed, classified as runtimeFatal, reported to Sentry,
//  and used to trigger the one-shot HLS fallback. `isCancellationError` is the
//  gate that stops that at every site; these tests pin its behaviour.
//
//  Pure tests: no engine, no view model. UniversalPlayerViewModel's init builds
//  a real player and Combine graph, so the load path itself is not reachable
//  from a unit test — the predicate is the testable seam.
//

import XCTest
@testable import Rivulet

final class CancellationClassificationTests: XCTestCase {

    // MARK: - Recognised cancellations

    func testStructuredConcurrencyCancellationIsCancellation() {
        XCTAssertTrue(isCancellationError(CancellationError()))
    }

    func testURLSessionMinus999IsCancellation() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertTrue(isCancellationError(error))
    }

    func testCocoaUserCancelledIsCancellation() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        XCTAssertTrue(isCancellationError(error))
    }

    /// A cancellation that arrived wrapped in URLError rather than as a bare
    /// NSError — same domain and code, so it must still be recognised.
    func testURLErrorCancelledIsCancellation() {
        XCTAssertTrue(isCancellationError(URLError(.cancelled)))
    }

    // MARK: - Real failures must NOT be swallowed

    func testGenuineLoadFailureIsNotCancellation() {
        let error = PlayerError.loadFailed("avformat_open_input failed")
        XCTAssertFalse(isCancellationError(error))
    }

    func testUnsupportedCodecIsNotCancellation() {
        XCTAssertFalse(isCancellationError(PlayerError.codecUnsupported("vc1")))
    }

    func testTimeoutIsNotCancellation() {
        XCTAssertFalse(isCancellationError(URLError(.timedOut)))
    }

    func testNotConnectedToInternetIsNotCancellation() {
        XCTAssertFalse(isCancellationError(URLError(.notConnectedToInternet)))
    }

    /// -999 belongs to NSURLErrorDomain. The same numeric code in an unrelated
    /// domain is a different error and must not be treated as a cancellation.
    func testMinus999InForeignDomainIsNotCancellation() {
        let error = NSError(domain: "com.rivulet.aether", code: NSURLErrorCancelled)
        XCTAssertFalse(isCancellationError(error))
    }

    /// The bug's signature. `PlayerError.loadFailed(String(describing:))` is
    /// exactly how AetherPlayer used to launder a CancellationError into a
    /// fatal-looking error; once wrapped it is unrecoverable, which is why the
    /// fix has to catch it before the wrap.
    func testWrappedCancellationIsUnrecognisable() {
        let wrapped = PlayerError.loadFailed(String(describing: CancellationError()))
        XCTAssertEqual(wrapped, .loadFailed("CancellationError()"))
        XCTAssertFalse(
            isCancellationError(wrapped),
            "Once wrapped the type is gone — the guard must run before the wrap, not after"
        )
    }

    /// The wrapped form also defeats the Sentry beforeSend drop list as it was
    /// originally written (`Code=-999` / lowercase `cancelled`), which is why
    /// the hook now matches "CancellationError" too.
    func testWrappedCancellationTextMissesOriginalSentryPredicate() {
        let text = String(describing: CancellationError())
        XCTAssertFalse(text.contains("Code=-999"))
        XCTAssertFalse(text.contains("cancelled"))
        XCTAssertTrue(text.contains("CancellationError"))
    }
}
