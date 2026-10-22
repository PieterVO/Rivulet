// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class PlaylistAvailabilityTests: XCTestCase {

    private func playlist(_ key: String, providerID: String) -> MediaPlaylist {
        let item = MediaItem(
            ref: MediaItemRef(providerID: providerID, itemID: key), kind: .playlist, title: "List \(key)",
            sortTitle: nil, overview: nil, year: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil)
        return MediaPlaylist(item: item, isSmart: false)
    }

    func test_refresh_keepsOnlyServersWithPlaylists() async {
        let availability = PlaylistAvailability()
        let some = StubMediaProvider(id: "plex:a")
        some.supportsPlaylists = true
        some.playlistList = [playlist("1", providerID: "plex:a")]
        let none = StubMediaProvider(id: "jellyfin:b")
        none.supportsPlaylists = true

        await availability.refresh(from: [some, none])

        XCTAssertEqual(availability.providerIDs, ["plex:a"])
    }

    /// The last playlist was deleted while an older refresh was still out: the older answer must not bring the row back.
    func test_olderRefreshFinishingLast_doesNotOverwriteNewer() async {
        let availability = PlaylistAvailability()
        let (entered, enteredGate) = AsyncStream<Void>.makeStream()
        let (release, releaseGate) = AsyncStream<Void>.makeStream()
        let slow = StubMediaProvider(id: "plex:a")
        slow.supportsPlaylists = true
        slow.playlistList = [playlist("1", providerID: "plex:a")]
        // An unstructured wait ignores the cancel, as a request already on the wire would.
        slow.playlistsGate = {
            enteredGate.yield()
            await Task { for await _ in release { break } }.value
        }
        let emptied = StubMediaProvider(id: "plex:a")
        emptied.supportsPlaylists = true

        let older = Task { await availability.refresh(from: [slow]) }
        for await _ in entered { break }
        await availability.refresh(from: [emptied])
        releaseGate.yield()
        await older.value

        XCTAssertEqual(availability.providerIDs, [])
    }
}
