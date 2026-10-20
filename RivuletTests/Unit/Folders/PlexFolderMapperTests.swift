// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Rows measured on PMS 1.43.4: a folder has only `key` and `title`.
final class PlexFolderMapperTests: XCTestCase {
    private func map(_ json: String) throws -> [FolderEntry] {
        let meta = try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
        return PlexFolderMapper.entries([meta], providerID: "plex:abc", serverURL: "http://s:32400", authToken: "tok")
    }

    func test_plexRowWithoutRatingKey_isFolder_withParentFromKey() throws {
        let entry = try XCTUnwrap(map(#"{"key":"/library/sections/16/folder?parent=32756","title":"10 Minute Trainer"}"#).first)
        guard case .folder(let ref, let count) = entry.content else { return XCTFail("not a folder") }
        XCTAssertEqual(ref.itemID, "32756")
        XCTAssertNil(count)
        XCTAssertEqual(entry.title, "10 Minute Trainer")
    }

    func test_plexMovieRow_isVideo() throws {
        let entry = try XCTUnwrap(map(#"{"ratingKey":"95176","key":"/library/metadata/95176","type":"movie","title":"Clip"}"#).first)
        guard case .video(let item) = entry.content else { return XCTFail("not a video") }
        XCTAssertEqual(item.id.itemID, "95176")
    }

    func test_plexEpisodeRow_isVideo() throws {
        let entry = try XCTUnwrap(map(#"{"ratingKey":"214321","key":"/library/metadata/214321","type":"episode","title":"Pilot"}"#).first)
        guard case .video = entry.content else { return XCTFail("not a video") }
    }
}
