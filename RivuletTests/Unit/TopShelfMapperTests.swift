import XCTest
@testable import Rivulet

final class TopShelfMapperTests: XCTestCase {

    // Follows the established codebase pattern: `var m = PlexMetadata()` then set
    // `var` fields (see PlexMediaMapperTests). PlexMetadata() is an all-defaulted init.
    private func meta(
        ratingKey: String,
        type: String,
        title: String,
        grandparentTitle: String? = nil,
        art: String? = nil,
        grandparentArt: String? = nil,
        parentThumb: String? = nil,
        thumb: String? = nil,
        lastViewedAt: Int? = nil
    ) -> PlexMetadata {
        var m = PlexMetadata()
        m.ratingKey = ratingKey
        m.type = type
        m.title = title
        m.grandparentTitle = grandparentTitle
        m.art = art
        m.grandparentArt = grandparentArt
        m.parentThumb = parentThumb
        m.thumb = thumb
        m.lastViewedAt = lastViewedAt
        return m
    }

    // `PlexMetadata.fullEpisodeTitle` always prefixes "S00E00 - " for any
    // metadata with type == "episode" (parentIndex/index default to 0 when
    // unset) — this is established production behavior in
    // PlexDataStore.updateTopShelfCache, preserved verbatim by the mapper.
    // Episode-title tests must account for this prefix rather than expect
    // the bare title.

    private let server = "http://plex.local:32400"
    private let token = "TESTTOKEN"

    // The regression guard for #194: a movie MUST survive mapping.
    func testMovieIsIncluded() {
        let input = [
            meta(ratingKey: "m1", type: "movie", title: "Blade Runner", art: "/art/m1", thumb: "/thumb/m1", lastViewedAt: 200),
            meta(ratingKey: "e1", type: "episode", title: "Ozymandias", grandparentTitle: "Breaking Bad", grandparentArt: "/art/bb", thumb: "/thumb/e1", lastViewedAt: 100)
        ]
        let items = TopShelfMapper.items(from: input, serverURL: server, token: token)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains { $0.ratingKey == "m1" }, "Movie must not be dropped (regression #194)")
    }

    func testSortedByLastViewedDescending() {
        let input = [
            meta(ratingKey: "a", type: "movie", title: "A", thumb: "/a", lastViewedAt: 50),
            meta(ratingKey: "b", type: "movie", title: "B", thumb: "/b", lastViewedAt: 300),
            meta(ratingKey: "c", type: "movie", title: "C", thumb: "/c", lastViewedAt: 150)
        ]
        let items = TopShelfMapper.items(from: input, serverURL: server, token: token)
        XCTAssertEqual(items.map(\.ratingKey), ["b", "c", "a"])
    }

    func testDedupeByRatingKeyKeepsFirst() {
        let input = [
            meta(ratingKey: "x", type: "movie", title: "First", thumb: "/1", lastViewedAt: 100),
            meta(ratingKey: "x", type: "movie", title: "Dup",   thumb: "/2", lastViewedAt: 100)
        ]
        let items = TopShelfMapper.items(from: input, serverURL: server, token: token)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "First")
    }

    func testCapsAtLimit() {
        let input = (0..<10).map { meta(ratingKey: "k\($0)", type: "movie", title: "T\($0)", thumb: "/\($0)", lastViewedAt: 10 - $0) }
        let items = TopShelfMapper.items(from: input, serverURL: server, token: token, limit: 5)
        XCTAssertEqual(items.count, 5)
    }

    func testEpisodeTextUsesEpisodeNameAndShowSubtitle() {
        let input = [meta(ratingKey: "e1", type: "episode", title: "Ozymandias", grandparentTitle: "Breaking Bad", grandparentArt: "/art/bb", lastViewedAt: 100)]
        let item = TopShelfMapper.items(from: input, serverURL: server, token: token).first
        // fullEpisodeTitle prefixes "S00E00 - " (parentIndex/index default to 0
        // when unset in the fixture) — established production behavior.
        XCTAssertEqual(item?.title, "S00E00 - Ozymandias")
        XCTAssertTrue(item?.title.contains("Ozymandias") ?? false)
        XCTAssertEqual(item?.subtitle, "Breaking Bad")
    }

    func testMovieHasNoSubtitle() {
        let input = [meta(ratingKey: "m1", type: "movie", title: "Blade Runner", thumb: "/t", lastViewedAt: 100)]
        let item = TopShelfMapper.items(from: input, serverURL: server, token: token).first
        XCTAssertNil(item?.subtitle)
    }

    func testWideURLPrefersBackdropAndCarriesToken() {
        let movie = meta(ratingKey: "m1", type: "movie", title: "M", art: "/art/m1", thumb: "/thumb/m1", lastViewedAt: 100)
        let ep    = meta(ratingKey: "e1", type: "episode", title: "E", grandparentTitle: "S", grandparentArt: "/art/bb", parentThumb: nil, thumb: "/thumb/e1", lastViewedAt: 90)
        let items = TopShelfMapper.items(from: [movie, ep], serverURL: server, token: token)
        let m = items.first { $0.ratingKey == "m1" }!
        let e = items.first { $0.ratingKey == "e1" }!
        XCTAssertTrue(m.wideImageURL.contains("/art/m1"))
        XCTAssertTrue(m.wideImageURL.contains("X-Plex-Token=\(token)"))
        XCTAssertTrue(e.wideImageURL.contains("/art/bb"))  // grandparentArt preferred for episode
    }

    func testWideURLFallsBackToThumbWhenNoBackdrop() {
        let movie = meta(ratingKey: "m1", type: "movie", title: "M", art: nil, thumb: "/thumb/only", lastViewedAt: 100)
        let item = TopShelfMapper.items(from: [movie], serverURL: server, token: token).first!
        XCTAssertTrue(item.wideImageURL.contains("/thumb/only"))
    }
}
