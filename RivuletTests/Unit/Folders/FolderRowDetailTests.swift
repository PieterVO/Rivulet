// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class FolderRowDetailTests: XCTestCase {
    private func video(runtime: TimeInterval?, offset: TimeInterval = 0, played: Bool = false) -> FolderEntry {
        let ref = MediaItemRef(providerID: "stub", itemID: "v")
        let item = MediaItem(
            ref: ref, kind: .movie, title: "Clip", sortTitle: nil, overview: nil, year: nil, runtime: runtime,
            parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: played, viewOffset: offset, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil)
        return FolderEntry(id: ref, title: "Clip", content: .video(item))
    }

    func test_folder_isChevron() {
        let ref = MediaItemRef(providerID: "stub", itemID: "f")
        XCTAssertEqual(FolderRowDetail.text(for: FolderEntry(id: ref, title: "F", content: .folder(ref, childCount: 3))), "›")
    }

    func test_watched_isCheckmark() {
        XCTAssertEqual(FolderRowDetail.text(for: video(runtime: 600, played: true)), "✓")
    }

    func test_inProgress_isTimeLeft() {
        XCTAssertEqual(FolderRowDetail.text(for: video(runtime: 600, offset: 240)), "6 min left")
    }

    func test_inProgressRewatch_outranksTheWatchedFlag() {
        XCTAssertEqual(FolderRowDetail.text(for: video(runtime: 600, offset: 240, played: true)), "6 min left")
    }

    func test_unwatched_isLength() {
        XCTAssertEqual(FolderRowDetail.text(for: video(runtime: 660)), "11 min")
        XCTAssertEqual(FolderRowDetail.text(for: video(runtime: 5520)), "1 hr 32 min")
        XCTAssertEqual(FolderRowDetail.text(for: video(runtime: nil)), "")
    }
}
