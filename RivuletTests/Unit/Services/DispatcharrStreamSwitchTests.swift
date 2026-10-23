// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DispatcharrStreamSwitchTests.swift
//  RivuletTests
//
//  Switching a Dispatcharr channel between its streams (#369). Response shapes
//  measured on Dispatcharr 0.32.0.
//

import XCTest
@testable import Rivulet

final class DispatcharrStreamSwitchTests: XCTestCase {

    private let base = "http://dispatcharr.test:9191"
    private let uuid = "26f8a8fa-9a15-47c7-99e3-8891c56d0f51"

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
        return DispatcharrService(baseURL: URL(string: base)!, apiToken: "key",
                                  session: URLSession(configuration: config))
    }

    private func mock(_ path: String, _ json: String, status: Int = 200) {
        MockURLProtocol.mockString(url: URL(string: base + path)!, content: json, statusCode: status,
                                   contentType: "application/json")
    }

    func test_channelUUID_onlyFromProxyStreamURLs() {
        XCTAssertEqual(DispatcharrService.channelUUID(fromStreamURL: URL(string: "\(base)/proxy/ts/stream/\(uuid)")!), uuid)
        XCTAssertNil(DispatcharrService.channelUUID(fromStreamURL: URL(string: "\(base)/live/user/pass/842")!))
        XCTAssertNil(DispatcharrService.channelUUID(fromStreamURL: URL(string: "\(base)/proxy/ts/stream/842")!))
    }

    func test_channelStreams_ordersAndMarksCurrent() async throws {
        mock("/api/channels/channels/by-uuids/", #"[{"id":842,"uuid":"\#(uuid)","streams":[1,2]}]"#)
        mock("/api/channels/channels/842/streams/", #"""
            [{"id":1,"name":"US| FOX 6","m3u_account":98,"stream_stats":{"height":1080,"source_fps":59.9}},
             {"id":2,"name":"US: FOX 6 HD","m3u_account":96,"stream_stats":null}]
            """#)
        mock("/api/m3u/accounts/", #"[{"id":98,"name":"TREX"},{"id":96,"name":"ProUHD"}]"#)
        mock("/proxy/ts/status/\(uuid)", #"{"stream_id":2,"state":"active"}"#)

        let result = try await makeService().channelStreams(channelUUID: uuid)

        XCTAssertEqual(result.streams.map(\.id), [1, 2])
        XCTAssertEqual(result.currentStreamID, 2)
        XCTAssertEqual(result.detail(for: result.streams[0]), "TREX • 1080p60")
        XCTAssertEqual(result.detail(for: result.streams[1]), "ProUHD")
        let lookup = MockURLProtocol.requestHistory.first { $0.url?.absoluteString.hasSuffix("by-uuids/") == true }
        XCTAssertEqual(lookup?.httpMethod, "POST")
        XCTAssertEqual(lookup?.value(forHTTPHeaderField: "X-API-Key"), "key")
    }

    func test_channelStreams_nonAdminKeyFails() async {
        mock("/api/channels/channels/by-uuids/", #"{"detail":"You do not have permission"}"#, status: 403)
        do {
            _ = try await makeService().channelStreams(channelUUID: uuid)
            XCTFail("expected a failure")
        } catch {}
    }

    func test_switchStream_postsToChangeStream() async throws {
        mock("/proxy/ts/change_stream/\(uuid)", #"{"message":"Stream changed successfully","stream_id":2}"#)

        try await makeService().switchStream(channelUUID: uuid, to: 2)

        let request = MockURLProtocol.requestHistory.last
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.path, "/proxy/ts/change_stream/\(uuid)")
    }
}
