// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DispatcharrSignInTests.swift
//  RivuletTests
//
//  Sign-in trades a username and password for the user's API key. Creating a
//  key replaces the old one, so an existing key must come back untouched.
//

import XCTest
@testable import Rivulet

final class DispatcharrSignInTests: XCTestCase {

    private let base = URL(string: "http://dispatcharr.test:9191")!
    private let tokenURL = URL(string: "http://dispatcharr.test:9191/api/accounts/token/")!
    private let keysURL = URL(string: "http://dispatcharr.test:9191/api/accounts/api-keys/")!
    private let generateURL = URL(string: "http://dispatcharr.test:9191/api/accounts/api-keys/generate/")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeService() -> DispatcharrService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return DispatcharrService(baseURL: base, session: URLSession(configuration: config))
    }

    func test_existingKeyIsReturned_neverRegenerated() async throws {
        MockURLProtocol.mockJSON(url: tokenURL, json: ["access": "jwt", "refresh": "r"])
        MockURLProtocol.mockJSON(url: keysURL, json: ["key": "existing"])

        let key = try await makeService().fetchAPIKey(username: "u", password: "p")

        XCTAssertEqual(key, "existing")
        XCTAssertFalse(MockURLProtocol.requestHistory.contains { $0.url == generateURL })
        let keyRequest = MockURLProtocol.requestHistory.first { $0.url == keysURL }
        XCTAssertEqual(keyRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
    }

    func test_noKeyYet_generatesOne() async throws {
        MockURLProtocol.mockJSON(url: tokenURL, json: ["access": "jwt", "refresh": "r"])
        MockURLProtocol.mockJSON(url: keysURL, json: ["key": NSNull()])
        MockURLProtocol.mockJSON(url: generateURL, json: ["key": "fresh"], statusCode: 201)

        let key = try await makeService().fetchAPIKey(username: "u", password: "p")

        XCTAssertEqual(key, "fresh")
    }
}
