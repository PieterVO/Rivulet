//
//  PersonFilmographyProviderTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

// MARK: - Fixtures

enum PersonFilmographyTestFixtures {
    static func playableItem(title: String, isMovie: Bool) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "plex:test", itemID: "rk-\(title)"),
            kind: isMovie ? .movie : .show,
            title: title,
            sortTitle: nil,
            overview: nil,
            year: nil,
            runtime: nil,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: nil,
            seasonNumber: nil,
            childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil,
            grandparentArtwork: nil
        )
    }
}

// MARK: - Tests

final class PersonFilmographyProviderTests: XCTestCase {
    func test_filmographyFromOriginLibraryAndTmdbBio() async throws {
        let provider = PersonFilmographyProvider(
            originLibraryItems: { _, _ in
                [PersonFilmographyTestFixtures.playableItem(title: "OnServerMovie", isMovie: true),
                 PersonFilmographyTestFixtures.playableItem(title: "OnServerShow", isMovie: false)]
            },
            personInfo: { _ in ("A bio.", URL(string: "https://image.tmdb.org/t/p/w780/p.jpg")) })
        let person = MediaPerson(id: "p", name: "Keanu Reeves", role: nil, imageURL: nil,
                                 originActorId: "49", originSectionKey: "1",
                                 titleTmdbId: 123, titleIsMovie: true)
        let detail = try await provider.load(person: person)
        XCTAssertEqual(detail.movies.map(\.item.title), ["OnServerMovie"])
        XCTAssertEqual(detail.shows.map(\.item.title), ["OnServerShow"])
        XCTAssertTrue(detail.movies.allSatisfy(\.isOnServer))
        XCTAssertEqual(detail.biography, "A bio.")
        XCTAssertEqual(detail.portraitURL?.absoluteString, "https://image.tmdb.org/t/p/w780/p.jpg")
    }

    func test_emptyFilmographyWhenNoOriginIds() async throws {
        let provider = PersonFilmographyProvider(
            originLibraryItems: { _, _ in XCTFail("should not query"); return [] },
            personInfo: { _ in (nil, nil) })
        let person = MediaPerson(id: "p", name: "Nobody", role: nil, imageURL: URL(string: "https://x/p.jpg"))
        let detail = try await provider.load(person: person)
        XCTAssertTrue(detail.movies.isEmpty)
        XCTAssertTrue(detail.shows.isEmpty)
        XCTAssertNil(detail.biography)
    }

    func test_portraitFallsBackToRoleThumbWhenTmdbNil() async throws {
        let provider = PersonFilmographyProvider(
            originLibraryItems: { _, _ in [] },
            personInfo: { _ in nil })
        let thumb = URL(string: "https://plex/role.jpg")
        let person = MediaPerson(id: "p", name: "X", role: nil, imageURL: thumb,
                                 originActorId: "1", originSectionKey: "1")
        let detail = try await provider.load(person: person)
        XCTAssertNil(detail.biography)
        XCTAssertEqual(detail.portraitURL, thumb)
    }
}
