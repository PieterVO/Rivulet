// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Shapes measured on Jellyfin 12.1.
@MainActor
final class JellyfinFolderMapperTests: XCTestCase {
    private func map(_ json: String) -> FolderEntry? {
        JellyfinFolderMapper.entry(JellyfinFixtures.decode(json), providerID: "jellyfin:srv", baseURL: JellyfinFixtures.baseURL)
    }

    func test_jellyfinFolderAndPhotoAlbum_areFolders() {
        for type in ["Folder", "PhotoAlbum", "Series", "Season", "BoxSet"] {
            let entry = map(#"{"Name":"Dir","Id":"d1","IsFolder":true,"Type":"\#(type)","ChildCount":9}"#)
            guard case .folder(let ref, let count)? = entry?.content else { return XCTFail("\(type) not a folder") }
            XCTAssertEqual(ref.itemID, "d1")
            XCTAssertEqual(count, 9)
        }
    }

    func test_jellyfinVideo_isVideo() {
        guard case .video? = map(#"{"Name":"Clip","Id":"v1","Type":"Video","RunTimeTicks":93983450,"ImageTags":{}}"#)?.content
        else { return XCTFail("not a video") }
    }

    func test_jellyfinPhoto_isPhoto() {
        guard case .photo? = map(#"{"Name":"p","Id":"p1","Type":"Photo","ImageTags":{"Primary":"t"}}"#)?.content
        else { return XCTFail("not a photo") }
    }

    func test_jellyfinUnknownType_isNil() {
        XCTAssertNil(map(#"{"Name":"Song","Id":"s1","Type":"Audio"}"#))
    }
}
