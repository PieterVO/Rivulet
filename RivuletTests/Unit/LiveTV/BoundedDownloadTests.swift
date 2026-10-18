// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class BoundedDownloadTests: XCTestCase {

    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private var config: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return config
    }

    func test_bodyUnderTheLimit_arrivesWhole() async throws {
        let url = URL(string: "https://iptv.example/list.m3u")!
        MockURLProtocol.mockData(url: url, data: Data(repeating: 7, count: 1000))
        let (data, response) = try await BoundedDownload.data(for: URLRequest(url: url), limit: 4096, configuration: config)
        XCTAssertEqual(data.count, 1000)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func test_bodyOverTheLimit_throwsInsteadOfBuffering() async {
        let url = URL(string: "https://iptv.example/huge.xml")!
        MockURLProtocol.mockData(url: url, data: Data(repeating: 7, count: 10_000))
        do {
            _ = try await BoundedDownload.data(for: URLRequest(url: url), limit: 4096, configuration: config)
            XCTFail("expected TooLarge")
        } catch {
            XCTAssertTrue(error is BoundedDownload.TooLarge, "\(error)")
        }
    }
}
