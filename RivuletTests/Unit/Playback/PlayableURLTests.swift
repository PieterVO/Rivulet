// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayableURLTests.swift
//  RivuletTests
//
//  Issue #255 follow-up. The same defect fixed in ContentRouter existed in the
//  provider-abstraction layer, built by string interpolation instead:
//
//      URL(string: "\(serverURL)\(part.key)?X-Plex-Token=\(token)")
//
//  When the key carries its own query string (IVA extras arrive as
//  /services/iva/assets/.../video.mp4?fmt=4&bitrate=5000) that yields TWO '?',
//  so the token is absorbed into the last parameter's value —
//  "bitrate=5000?X-Plex-Token=TOK" — and never authenticates. The server sees
//  an unauthenticated request rather than a malformed path, so this fails
//  differently from the ContentRouter case but from the identical cause.
//
//  The load-bearing assertion throughout is that X-Plex-Token survives as a
//  REAL query item. A URL that merely looks right but whose token is buried in
//  another value is the exact bug.
//
//  Pure tests: no network.
//

import XCTest
@testable import Rivulet

final class PlayableURLTests: XCTestCase {

    private let server = "https://example.plex.direct:32400"
    private let token = "TOK"

    private func items(_ url: URL?) -> [String: String] {
        guard let url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        return Dictionary(
            (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { a, _ in a }
        )
    }

    // MARK: - Ordinary library part keys

    func test_libraryPartKey_buildsTokenizedURL() {
        let url = PlexMediaMapper.playableURL(
            "/library/parts/98765/1234567890/file.mkv", serverURL: server, authToken: token
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://example.plex.direct:32400/library/parts/98765/1234567890/file.mkv?X-Plex-Token=TOK"
        )
    }

    // MARK: - IVA keys carrying a query string — the defect

    func test_ivaKey_preservesItsOwnParameters() {
        let url = PlexMediaMapper.playableURL(
            "/services/iva/assets/715933/video.mp4?fmt=4&bitrate=5000",
            serverURL: server, authToken: token
        )
        let q = items(url)
        XCTAssertEqual(q["fmt"], "4")
        XCTAssertEqual(q["bitrate"], "5000")
    }

    /// The precise failure: the token must be its OWN query item, not swallowed
    /// into the preceding parameter's value.
    func test_ivaKey_tokenIsARealQueryItem() {
        let url = PlexMediaMapper.playableURL(
            "/services/iva/assets/715933/video.mp4?fmt=4&bitrate=5000",
            serverURL: server, authToken: token
        )
        let q = items(url)
        XCTAssertEqual(q["X-Plex-Token"], "TOK", "token must authenticate as its own parameter")
        XCTAssertEqual(q["bitrate"], "5000", "token must not be absorbed into bitrate's value")
        XCTAssertFalse(
            url?.absoluteString.contains("5000?X-Plex-Token") ?? true,
            "two '?' in the URL is the #255 corruption"
        )
    }

    func test_ivaKey_producesExactlyOneQueryDelimiter() {
        let url = PlexMediaMapper.playableURL(
            "/services/iva/assets/715933/video.mp4?fmt=4&bitrate=5000",
            serverURL: server, authToken: token
        )
        XCTAssertEqual(url?.absoluteString.filter { $0 == "?" }.count, 1)
        XCTAssertFalse(url?.absoluteString.contains("%3F") ?? true)
    }

    func test_ivaKey_pathExcludesTheQueryString() {
        let url = PlexMediaMapper.playableURL(
            "/services/iva/assets/715933/video.mp4?fmt=4&bitrate=5000",
            serverURL: server, authToken: token
        )
        XCTAssertEqual(url?.path, "/services/iva/assets/715933/video.mp4")
    }

    // MARK: - Degenerate input

    func test_nilKey_returnsNil() {
        XCTAssertNil(PlexMediaMapper.playableURL(nil, serverURL: server, authToken: token))
    }

    func test_emptyKey_returnsNil() {
        XCTAssertNil(PlexMediaMapper.playableURL("", serverURL: server, authToken: token))
    }
}
