//
//  InsightsShowIDResolutionTests.swift
//  RivuletTests
//
//  Covers the client-side show-TMDB-id resolution that feeds Insights for TV
//  episodes. The bug this guards against: episodes carry a plex:// or tvdb://
//  grandparent guid (not tmdb://), so the old direct extraction returned nil
//  and Insights silently bailed — never fetching or requesting generation.
//

import XCTest
@testable import Rivulet

final class InsightsShowIDResolutionTests: XCTestCase {

    // MARK: - External-id extraction

    func testExtractTvdbId() {
        XCTAssertEqual(PlexMetadata.extractTvdbId(from: "tvdb://409104"), 409104)
        XCTAssertEqual(PlexMetadata.extractTvdbId(from: "tvdb://371980?lang=en"), 371980)
        XCTAssertNil(PlexMetadata.extractTvdbId(from: "tmdb://12345"))
        XCTAssertNil(PlexMetadata.extractTvdbId(from: "plex://show/abc"))
    }

    func testExtractImdbId() {
        XCTAssertEqual(PlexMetadata.extractImdbId(from: "imdb://tt31510819"), "tt31510819")
        XCTAssertEqual(PlexMetadata.extractImdbId(from: "imdb://tt11198330/"), "tt11198330")
        XCTAssertNil(PlexMetadata.extractImdbId(from: "tvdb://409104"))
        XCTAssertNil(PlexMetadata.extractImdbId(from: "imdb://notanid"))
    }

    // MARK: - showExternalIDs on an episode

    func testShowExternalIDsFromGuidArray() {
        // Modern Plex agent: plex:// grandparent guid, real ids in Guid[].
        var m = PlexMetadata()
        m.type = "episode"
        m.grandparentGuid = "plex://show/5d9c08fd"
        m.Guid = [
            PlexGuid(id: "tvdb://409104"),
            PlexGuid(id: "imdb://tt31510819"),
        ]
        let ids = m.showExternalIDs
        XCTAssertNil(ids.tmdb)
        XCTAssertEqual(ids.tvdb, 409104)
        XCTAssertEqual(ids.imdb, "tt31510819")
    }

    func testShowExternalIDsPrefersDirectTmdbGuid() {
        var m = PlexMetadata()
        m.type = "episode"
        m.grandparentGuid = "tmdb://240411"
        let ids = m.showExternalIDs
        XCTAssertEqual(ids.tmdb, 240411)
    }

    func testShowExternalIDsEmptyWhenNoGuids() {
        var m = PlexMetadata()
        m.type = "episode"
        let ids = m.showExternalIDs
        XCTAssertNil(ids.tmdb)
        XCTAssertNil(ids.tvdb)
        XCTAssertNil(ids.imdb)
    }

    // MARK: - Resolver: direct tmdb id short-circuits (no network)

    func testResolverReturnsDirectTmdbWithoutNetwork() async {
        // A stub session that fails any request — proves the tmdb short-circuit
        // never touches the network.
        let resolver = InsightsShowIDResolver(
            baseURL: URL(string: "https://example.invalid")!,
            session: Self.failingSession()
        )
        let id = await resolver.resolve(ShowExternalIDs(tmdb: 999, tvdb: 111, imdb: "tt1"))
        XCTAssertEqual(id, 999)
    }

    private static func failingSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FailingProtocol.self]
        return URLSession(configuration: cfg)
    }

    private final class FailingProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }
}
