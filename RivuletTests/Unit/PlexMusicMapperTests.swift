//
//  PlexMusicMapperTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class PlexMusicMapperTests: XCTestCase {

    // MARK: - Artist

    func test_artist_maps_name_and_ref() {
        var meta = PlexMetadata()
        meta.ratingKey = "100"
        meta.type = "artist"
        meta.title = "Radiohead"
        meta.thumb = "/library/metadata/100/thumb/123"

        let artist = PlexMusicMapper.artist(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )

        XCTAssertEqual(artist.name, "Radiohead")
        XCTAssertEqual(artist.ref.providerID, "plex:abc")
        XCTAssertEqual(artist.ref.itemID, "100")
        XCTAssertNotNil(artist.artwork.thumbnail)
    }

    func test_artist_user_state_from_userRating() {
        var meta = PlexMetadata()
        meta.ratingKey = "100"
        meta.type = "artist"
        meta.title = "X"
        meta.userRating = 8          // Plex 0-10 scale
        meta.viewCount = 42

        let artist = PlexMusicMapper.artist(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )

        XCTAssertTrue(artist.userState.isFavorite)
        XCTAssertEqual(artist.userState.userRating, 4.0) // 8/2 normalized to 5-star
        XCTAssertEqual(artist.userState.playCount, 42)
    }

    func test_userState_unrated_is_not_favorite() {
        var meta = PlexMetadata()
        meta.ratingKey = "99"
        meta.type = "artist"
        meta.title = "Y"
        // userRating left nil

        let artist = PlexMusicMapper.artist(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )

        XCTAssertFalse(artist.userState.isFavorite)
        XCTAssertNil(artist.userState.userRating)
    }

    // MARK: - Album

    func test_album_maps_title_year_and_artist_link() {
        var meta = PlexMetadata()
        meta.ratingKey = "200"
        meta.type = "album"
        meta.title = "OK Computer"
        meta.parentRatingKey = "100"
        meta.parentTitle = "Radiohead"
        meta.year = 1997
        meta.leafCount = 12

        let album = PlexMusicMapper.album(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )

        XCTAssertEqual(album.title, "OK Computer")
        XCTAssertEqual(album.year, 1997)
        XCTAssertEqual(album.trackCount, 12)
        XCTAssertEqual(album.artistRef?.itemID, "100")
        XCTAssertEqual(album.artistName, "Radiohead")
    }

    // MARK: - Track

    func test_track_maps_number_duration_and_hierarchy() {
        var meta = PlexMetadata()
        meta.ratingKey = "300"
        meta.type = "track"
        meta.title = "Paranoid Android"
        meta.parentRatingKey = "200"
        meta.parentTitle = "OK Computer"
        meta.grandparentRatingKey = "100"
        meta.grandparentTitle = "Radiohead"
        meta.index = 2                   // track number
        meta.duration = 383_000          // ms

        let track = PlexMusicMapper.track(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )

        XCTAssertEqual(track.title, "Paranoid Android")
        XCTAssertEqual(track.trackNumber, 2)
        XCTAssertEqual(track.duration, 383.0)
        XCTAssertEqual(track.albumRef?.itemID, "200")
        XCTAssertEqual(track.albumTitle, "OK Computer")
        XCTAssertEqual(track.artistRef?.itemID, "100")
        XCTAssertEqual(track.artistName, "Radiohead")
    }

    func test_track_maps_discNumber_from_parentIndex() {
        var meta = PlexMetadata()
        meta.ratingKey = "301"
        meta.type = "track"
        meta.title = "Side B Track"
        meta.index = 1
        meta.parentIndex = 2          // disc 2
        meta.duration = 180_000

        let track = PlexMusicMapper.track(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )

        XCTAssertEqual(track.discNumber, 2)
    }

    func test_track_discNumber_nil_when_no_parentIndex() {
        var meta = PlexMetadata()
        meta.ratingKey = "302"
        meta.type = "track"
        meta.title = "Single-disc Track"
        meta.index = 3
        meta.duration = 200_000
        // parentIndex left unset

        let track = PlexMusicMapper.track(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )

        XCTAssertNil(track.discNumber)
    }

    // MARK: - MusicItem dispatch

    func test_item_dispatches_artist() {
        var meta = PlexMetadata()
        meta.ratingKey = "100"
        meta.type = "artist"
        meta.title = "Radiohead"
        let item = PlexMusicMapper.item(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )
        XCTAssertEqual(item?.kind, .artist)
    }

    func test_item_dispatches_album() {
        var meta = PlexMetadata()
        meta.ratingKey = "200"
        meta.type = "album"
        meta.title = "X"
        let item = PlexMusicMapper.item(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )
        XCTAssertEqual(item?.kind, .album)
    }

    func test_item_dispatches_track() {
        var meta = PlexMetadata()
        meta.ratingKey = "300"
        meta.type = "track"
        meta.title = "X"
        meta.duration = 100
        let item = PlexMusicMapper.item(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )
        XCTAssertEqual(item?.kind, .track)
    }

    func test_item_returns_nil_for_non_music_type() {
        var meta = PlexMetadata()
        meta.ratingKey = "500"
        meta.type = "movie"
        meta.title = "X"
        let item = PlexMusicMapper.item(
            meta, providerID: "plex:abc",
            serverURL: "https://x", authToken: "T"
        )
        XCTAssertNil(item)
    }
}
