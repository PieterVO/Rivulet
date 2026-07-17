// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class TopShelfCompositeStoreTests: XCTestCase {

    func testWriteThenReadComposite() throws {
        let cache = TopShelfCache.shared
        guard cache.compositeDirectoryURL() != nil else {
            throw XCTSkip("App Group container unavailable in this test host")
        }
        let data = Data([0xFF, 0xD8, 0xFF])  // JPEG magic-ish
        XCTAssertTrue(cache.writeComposite(data, fileName: "test-rk.jpg"))
        let url = cache.compositeFileURL(fileName: "test-rk.jpg")
        XCTAssertNotNil(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path))
        // cleanup
        cache.pruneComposites(keeping: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url!.path))
    }

    func testPruneKeepsListedDeletesOthers() throws {
        let cache = TopShelfCache.shared
        guard cache.compositeDirectoryURL() != nil else {
            throw XCTSkip("App Group container unavailable in this test host")
        }
        _ = cache.writeComposite(Data([0x1]), fileName: "keep.jpg")
        _ = cache.writeComposite(Data([0x2]), fileName: "drop.jpg")
        cache.pruneComposites(keeping: ["keep.jpg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.compositeFileURL(fileName: "keep.jpg")!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.compositeFileURL(fileName: "drop.jpg")!.path))
        cache.pruneComposites(keeping: [])
    }
}
