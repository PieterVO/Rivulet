// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EPGMergeTests.swift
//  RivuletTests
//
//  How a fetched guide range merges into the loaded guide (fill and refresh).
//

import XCTest
@testable import Rivulet

final class EPGMergeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func program(_ id: String, _ from: TimeInterval, _ to: TimeInterval, channel: String = "c") -> UnifiedProgram {
        UnifiedProgram(id: id, channelId: channel, title: id,
                       startTime: t0.addingTimeInterval(from * 3600), endTime: t0.addingTimeInterval(to * 3600))
    }

    func test_refreshReplacesRangeAndKeepsTheRest() {
        let loaded = ["c": [program("a", 0, 1), program("b", 1, 2), program("far", 30, 31)]]
        // The schedule changed: "b" ran long and became "b2".
        let fetched = ["c": [program("a", 0, 1), program("b2", 1, 3)]]
        let merged = LiveTVDataStore.merging(fetched, into: loaded, from: t0, to: t0.addingTimeInterval(6 * 3600))
        XCTAssertEqual(merged["c"]?.map(\.id), ["a", "b2", "far"])
    }

    func test_extensionDedupesTheBoundaryProgramme() {
        let loaded = ["c": [program("a", 0, 5), program("edge", 5, 7)]]
        let fetched = ["c": [program("edge", 5, 7), program("next", 7, 8)]]
        let merged = LiveTVDataStore.merging(fetched, into: loaded,
                                             from: t0.addingTimeInterval(6 * 3600), to: t0.addingTimeInterval(30 * 3600))
        XCTAssertEqual(merged["c"]?.map(\.id), ["a", "edge", "next"])
    }

    func test_channelMissingFromFetchKeepsItsGuide() {
        let loaded = ["c": [program("a", 0, 1)], "d": [program("x", 0, 1, channel: "d")]]
        let merged = LiveTVDataStore.merging(["c": []], into: loaded, from: t0, to: t0.addingTimeInterval(3600))
        XCTAssertEqual(merged["d"]?.map(\.id), ["x"])
        XCTAssertEqual(merged["c"]?.map(\.id), [])
    }
}
