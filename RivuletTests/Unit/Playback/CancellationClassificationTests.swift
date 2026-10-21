// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CancellationClassificationTests.swift
//  RivuletTests
//
//  `isCancellationError`: an ordinary task cancellation must not become a load
//  failure, a Sentry report or an HLS fallback (RIVULET-19).
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

    /// Once wrapped in `PlayerError.loadFailed`, a cancellation is unrecognisable,
    /// so the guard must run before the wrap.
    func testWrappedCancellationIsUnrecognisable() {
        let wrapped = PlayerError.loadFailed(String(describing: CancellationError()))
        XCTAssertEqual(wrapped, .loadFailed("CancellationError()"))
        XCTAssertFalse(
            isCancellationError(wrapped),
            "Once wrapped the type is gone — the guard must run before the wrap, not after"
        )
    }

    /// The wrapped text has no `Code=-999` or `cancelled`, so the Sentry
    /// beforeSend drop list also matches "CancellationError".
    func testWrappedCancellationTextMissesOriginalSentryPredicate() {
        let text = String(describing: CancellationError())
        XCTAssertFalse(text.contains("Code=-999"))
        XCTAssertFalse(text.contains("cancelled"))
        XCTAssertTrue(text.contains("CancellationError"))
    }
}
