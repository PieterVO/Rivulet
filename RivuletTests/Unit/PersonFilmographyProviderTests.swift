//
//  PersonFilmographyProviderTests.swift
//  RivuletTests
//
//  TDD tests for PersonFilmographyProvider (Task 5).
//

import XCTest
@testable import Rivulet

// MARK: - Fakes

private struct FakeFetcher: DiscoverPersonFetching {
    let dto: DiscoverPersonDTO
    func fetch(tagKey: String) async throws -> DiscoverPersonDTO { dto }
}

private struct ThrowingFetcher: DiscoverPersonFetching {
    func fetch(tagKey: String) async throws -> DiscoverPersonDTO {
        throw URLError(.badServerResponse)
    }
}

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

    func test_partitionsServerFirstAndBucketsByType() async throws {
        let dto = DiscoverPersonDTO(
            name: "Jon Hamm", biography: "Bio", portraitURL: nil,
            titles: [
                .init(guids: ["tmdb://1"], isMovie: true,  title: "OnServerMovie",  year: 2010, posterURL: nil),
                .init(guids: ["tmdb://2"], isMovie: true,  title: "OffServerMovie", year: 2016, posterURL: nil),
                .init(guids: ["tmdb://3"], isMovie: false, title: "OnServerShow",   year: 2007, posterURL: nil),
            ])

        // Only tmdb://1 and tmdb://3 are "on server".
        let onServer: Set<String> = ["tmdb://1", "tmdb://3"]
        let provider = PersonFilmographyProvider(
            fetcher: FakeFetcher(dto: dto),
            serverItemForGuids: { guids in
                for g in guids where onServer.contains(g) {
                    return PersonFilmographyTestFixtures.playableItem(
                        title: g == "tmdb://1" ? "OnServerMovie" : "OnServerShow",
                        isMovie: g == "tmdb://1")
                }
                return nil
            })

        let person = MediaPerson(id: "p", name: "Jon Hamm", role: nil, imageURL: nil, tagKey: "5d77")
        let detail = try await provider.load(person: person)

        // Movies: server entry first, then off-server.
        XCTAssertEqual(detail.movies.map(\.isOnServer), [true, false])
        XCTAssertEqual(detail.movies.map(\.item.title), ["OnServerMovie", "OffServerMovie"])

        // Shows: only one on-server entry.
        XCTAssertEqual(detail.shows.count, 1)
        XCTAssertTrue(detail.shows[0].isOnServer)

        // Biography passes through from the DTO.
        XCTAssertEqual(detail.biography, "Bio")
    }

    func test_fallsBackWhenNoTagKey() async throws {
        // person with no tagKey -> loadFallback: name preserved, empty rows, no throw.
        let provider = PersonFilmographyProvider(
            fetcher: FakeFetcher(dto: DiscoverPersonDTO(name: "X", biography: nil, portraitURL: nil, titles: [])),
            serverItemForGuids: { _ in nil })
        let person = MediaPerson(id: "p", name: "Cillian Murphy", role: nil, imageURL: nil, tagKey: nil)
        let detail = try await provider.load(person: person)

        XCTAssertEqual(detail.name, "Cillian Murphy")
        XCTAssertTrue(detail.movies.isEmpty)
        XCTAssertTrue(detail.shows.isEmpty)
    }

    func test_fallsBackWhenFetchThrows() async throws {
        // Fetch throws -> degrades to fallback, not a thrown error from load.
        let provider = PersonFilmographyProvider(
            fetcher: ThrowingFetcher(),
            serverItemForGuids: { _ in nil })
        let person = MediaPerson(id: "p", name: "Cillian Murphy", role: nil, imageURL: nil, tagKey: "abc")
        let detail = try await provider.load(person: person)

        // load must not throw; name is preserved; rows are empty.
        XCTAssertEqual(detail.name, "Cillian Murphy")
        XCTAssertTrue(detail.movies.isEmpty)
        XCTAssertTrue(detail.shows.isEmpty)
    }

    func test_usesDTONameWhenNonEmpty() async throws {
        // When the DTO has a non-empty name, it should override the MediaPerson name.
        let dto = DiscoverPersonDTO(name: "Jonathan Daniel Hamm", biography: nil, portraitURL: nil, titles: [])
        let provider = PersonFilmographyProvider(
            fetcher: FakeFetcher(dto: dto),
            serverItemForGuids: { _ in nil })
        let person = MediaPerson(id: "p", name: "Jon Hamm", role: nil, imageURL: nil, tagKey: "5d77")
        let detail = try await provider.load(person: person)
        XCTAssertEqual(detail.name, "Jonathan Daniel Hamm")
    }

    func test_fallsBackToPersonNameWhenDTONameEmpty() async throws {
        // When the DTO name is empty, fall back to MediaPerson.name.
        let dto = DiscoverPersonDTO(name: "", biography: nil, portraitURL: nil, titles: [])
        let provider = PersonFilmographyProvider(
            fetcher: FakeFetcher(dto: dto),
            serverItemForGuids: { _ in nil })
        let person = MediaPerson(id: "p", name: "Jon Hamm", role: nil, imageURL: nil, tagKey: "5d77")
        let detail = try await provider.load(person: person)
        XCTAssertEqual(detail.name, "Jon Hamm")
    }
}
