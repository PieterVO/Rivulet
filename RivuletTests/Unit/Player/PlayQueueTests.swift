// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class PlayQueueTests: XCTestCase {

    private func entry(_ id: String, item: String? = nil, kind: MediaKind = .movie,
                       played: Bool = false, offset: TimeInterval = 0) -> PlaylistEntry {
        let media = MediaItem(
            ref: MediaItemRef(providerID: "plex:a", itemID: item ?? id), kind: kind, title: item ?? id,
            sortTitle: nil, overview: nil, year: nil, runtime: 3600, parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: played, viewOffset: offset, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil)
        return PlaylistEntry(entryID: id, item: media)
    }

    func test_next_crossesMovieToEpisode() {
        let queue = PlayQueue(entries: [entry("1"), entry("2", kind: .episode)], startingAt: 0)!
        XCTAssertEqual(queue.next?.item.kind, .episode)
    }

    func test_lastItem_hasNoNext() {
        XCTAssertNil(PlayQueue(entries: [entry("1"), entry("2")], startingAt: 1)!.next)
    }

    func test_duplicates_advanceByIndex() {
        var queue = PlayQueue(entries: [entry("e1", item: "A"), entry("e2", item: "B"), entry("e3", item: "A")], startingAt: 0)!
        queue.advance()
        queue.advance()
        XCTAssertEqual(queue.index, 2)
        XCTAssertEqual(queue.current.entryID, "e3")
    }

    func test_advance_onLast_staysPut() {
        var queue = PlayQueue(entries: [entry("1"), entry("2")], startingAt: 1)!
        queue.advance()
        XCTAssertEqual(queue.index, 1)
    }

    func test_continuePoint_nilWhenNothingWatched() {
        XCTAssertNil(PlayQueue.continuePoint(in: [entry("1"), entry("2")]))
    }

    func test_continuePoint_nilWhenAllWatched() {
        XCTAssertNil(PlayQueue.continuePoint(in: [entry("1", played: true), entry("2", played: true)]))
    }

    func test_continuePoint_firstUnwatchedAfterProgress() {
        let entries = [entry("1", played: true), entry("2", offset: 1800), entry("3")]
        XCTAssertEqual(PlayQueue.continuePoint(in: entries), 1)
    }

    func test_shuffled_keepsEveryEntry() {
        let entries = [entry("1", item: "A"), entry("2", item: "A"), entry("3"), entry("4")]
        let queue = PlayQueue.shuffled(entries)!
        XCTAssertEqual(queue.index, 0)
        XCTAssertEqual(Set(queue.entries), Set(entries))
        XCTAssertEqual(queue.entries.count, entries.count)
    }

    func test_emptyEntries_hasNoQueue() {
        XCTAssertNil(PlayQueue<PlaylistEntry>(entries: [], startingAt: 0))
        XCTAssertNil(PlayQueue<PlaylistEntry>.shuffled([]))
    }

    func test_continuePoint_inProgressOnly_isFirstEntry() {
        XCTAssertEqual(PlayQueue.continuePoint(in: [entry("1", offset: 1800), entry("2")]), 0)
    }

    func test_jump_clampsToValidRange() {
        var queue = PlayQueue(entries: [entry("1"), entry("2"), entry("3")], startingAt: 0)!
        queue.jump(to: 9)
        XCTAssertEqual(queue.index, 2)
        queue.jump(to: -4)
        XCTAssertEqual(queue.index, 0)
    }
}
