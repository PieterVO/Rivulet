// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexProviderWatchlistTests.swift
//  RivuletTests
//
//  Issue #269: the detail view's watchlist button always read "+" because the
//  provider answered false for every Plex-rooted ref. It now resolves the
//  item's tmdb guid, which for an episode means the SHOW's guid.
//

import XCTest
@testable import Rivulet

final class PlexProviderWatchlistTests: XCTestCase {

    private final class StubNetwork: PlexNetworkManager {
        var items: [String: PlexMetadata] = [:]
        override func getFullMetadata(
            serverURL: String, authToken: String, ratingKey: String
        ) async throws -> PlexMetadata {
            guard let item = items[ratingKey] else { throw PlexAPIError.invalidURL }
            return item
        }
    }

    private func makeProvider(_ network: StubNetwork) -> PlexProvider {
        PlexProvider(
            machineIdentifier: "test", displayName: "Test",
            serverURL: "http://plex.test", authToken: "t",
            networkManager: network
        )
    }

    private func ref(_ id: String) -> MediaItemRef {
        MediaItemRef(providerID: "plex:test", itemID: id)
    }

    func testMovieResolvesItsOwnGuid() async {
        let network = StubNetwork()
        var movie = PlexMetadata()
        movie.type = "movie"
        movie.guid = "tmdb://603"
        network.items["1"] = movie

        let guids = await makeProvider(network).watchlistGUIDs(ref("1"))
        XCTAssertEqual(guids, ["tmdb://603"])
    }

    func testEpisodeResolvesToItsShow() async {
        let network = StubNetwork()
        var episode = PlexMetadata()
        episode.type = "episode"
        episode.guid = "tmdb://999999"          // episode-level id, never watchlisted
        episode.grandparentRatingKey = "show-7"
        var show = PlexMetadata()
        show.type = "show"
        show.guid = "tmdb://1396"
        network.items["ep-1"] = episode
        network.items["show-7"] = show

        let guids = await makeProvider(network).watchlistGUIDs(ref("ep-1"))
        XCTAssertEqual(guids, ["tmdb://1396"])
    }

    func testSeasonResolvesToItsShow() async {
        let network = StubNetwork()
        var season = PlexMetadata()
        season.type = "season"
        season.parentRatingKey = "show-7"
        var show = PlexMetadata()
        show.type = "show"
        show.guid = "tmdb://1396"
        network.items["s-1"] = season
        network.items["show-7"] = show

        let guids = await makeProvider(network).watchlistGUIDs(ref("s-1"))
        XCTAssertEqual(guids, ["tmdb://1396"])
    }

    /// The TheTVDB agent stores its id in the primary guid and leaves the Guid
    /// array empty. Requiring tmdb here is what made adding such a show a no-op.
    func testTvdbOnlyShowStillResolves() async {
        let network = StubNetwork()
        var show = PlexMetadata()
        show.type = "show"
        show.guid = "com.plexapp.agents.thetvdb://266189?lang=en"
        network.items["1"] = show

        let guids = await makeProvider(network).watchlistGUIDs(ref("1"))
        XCTAssertEqual(guids, ["tvdb://266189"])
    }

    /// Modern agent: plex:// primary guid, externals in the Guid array. All of
    /// them go into the stub so a later `contains` answers for any one of them.
    func testGuidArrayYieldsAllExternalsTmdbFirst() async {
        let network = StubNetwork()
        var show = PlexMetadata()
        show.type = "show"
        show.guid = "plex://show/5d9c0874"
        show.Guid = [
            PlexGuid(id:"tvdb://266189"),
            PlexGuid(id:"imdb://tt3830558"),
            PlexGuid(id:"tmdb://61888")
        ]
        network.items["1"] = show

        let guids = await makeProvider(network).watchlistGUIDs(ref("1"))
        XCTAssertEqual(guids, ["tmdb://61888", "imdb://tt3830558", "tvdb://266189"])
    }

    /// An unmatched item (home video, no agent match) has no external guid at
    /// all — it genuinely can't be watchlisted, so empty is the honest answer.
    func testUnmatchedItemHasNoGUID() async {
        let network = StubNetwork()
        var movie = PlexMetadata()
        movie.type = "movie"
        movie.guid = "local://abc123"
        network.items["1"] = movie

        let guids = await makeProvider(network).watchlistGUIDs(ref("1"))
        XCTAssertTrue(guids.isEmpty)
    }
}
