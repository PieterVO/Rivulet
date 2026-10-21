// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinLiveTVTests.swift
//  RivuletTests
//
//  Jellyfin Live TV mapping and stream lifecycle, from responses measured on
//  a 12.1 server (M3U tuner + XMLTV guide), and the automatic-source rules.
//

import XCTest
@testable import Rivulet

@MainActor
final class JellyfinLiveTVTests: XCTestCase {
    private let server = FakeJellyfinServer()
    private let base = JellyfinFixtures.baseURL

    private func provider() -> JellyfinLiveTVProvider {
        JellyfinLiveTVProvider(provider: JellyfinProvider(
            serverID: "srv", displayName: "NAS", userID: "user-1",
            client: JellyfinClient(baseURL: base, token: "tok", transport: server.transport)))
    }

    // Trimmed from GET /LiveTv/Channels (addCurrentProgram=false, enableUserData=true).
    private let channels = #"""
        {"Items":[
          {"Name":"FOX 6 WBRC","Id":"746bd1ff6d4432d20768254840f0acbc","Number":"6","ChannelNumber":"6",
           "Type":"TvChannel","UserData":{"IsFavorite":true},"ImageTags":{"Primary":"c6273926e8951a56a888bfa92185676d"},
           "ChannelType":"TV"},
          {"Name":"WXYZ-DT","Id":"0d8f985317adb9bbdd425926e0096b8f","Number":"5.1","ChannelNumber":"5.1",
           "Type":"TvChannel","UserData":{"IsFavorite":false},"ImageTags":{},"ChannelType":"TV"}],
         "TotalRecordCount":2,"StartIndex":0}
        """#

    // Trimmed from GET /LiveTv/Programs (fields=Overview,Genres).
    private let programs = #"""
        {"Items":[
          {"Name":"Live: Big Money in the Morning","Id":"96e30a15b21d64a91ef7b69e6d5090f1",
           "ChannelId":"746bd1ff6d4432d20768254840f0acbc","Overview":"Market trends.",
           "Genres":["Series","Bus./financial","News"],"ProductionYear":2026,"IndexNumber":22,"ParentIndexNumber":1,
           "Type":"Program","ImageTags":{"Primary":"be80e079273ae3ff0cf01d5d223052cd"},"BackdropImageTags":[],
           "EndDate":"2026-10-21T13:00:00.0000000Z","StartDate":"2026-10-21T10:00:00.0000000Z",
           "IsSeries":true,"IsNews":true,"IsPremiere":true,"EpisodeTitle":"Fed Day"},
          {"Name":"Good Day Alabama 7a","Id":"9bda42931e07bc1d67504d37bce51ddc",
           "ChannelId":"746bd1ff6d4432d20768254840f0acbc","Genres":[],"Type":"Program","ImageTags":{},
           "EndDate":"2026-10-21T09:00:00.0000000Z","StartDate":"2026-10-21T08:00:00.0000000Z","IsNews":true},
          {"Name":"Elsewhere","Id":"p3","ChannelId":"not-in-lineup",
           "EndDate":"2026-10-21T09:00:00.0000000Z","StartDate":"2026-10-21T08:00:00.0000000Z"}]}
        """#

    // Trimmed from POST /Items/{channel}/PlaybackInfo with AutoOpenLiveStream.
    private let playbackInfo = #"""
        {"MediaSources":[{"Protocol":"Http","Id":"4b60385fcaf0891c48a75fc26c573622","Container":"ts",
          "SupportsDirectPlay":true,"SupportsDirectStream":true,"SupportsTranscoding":true,"IsInfiniteStream":true,
          "RequiresOpening":true,"RequiresClosing":true,
          "LiveStreamId":"e2329f_af999c_4b6038"}],
         "PlaySessionId":"bba53d2aa73f4c6cbf924e7a2f640ad8"}
        """#

    // MARK: - Channels

    func test_channels_mapLogoNumberAndFavourite() async throws {
        server.respond("/LiveTv/Channels", body: channels)
        let result = try await provider().refreshChannels()

        XCTAssertEqual(result.map(\.id), ["jellyfin:jellyfin:srv:746bd1ff6d4432d20768254840f0acbc",
                                          "jellyfin:jellyfin:srv:0d8f985317adb9bbdd425926e0096b8f"])
        XCTAssertEqual(result[0].sourceType, .jellyfin)
        XCTAssertEqual(result[0].channelNumber, 6)
        XCTAssertTrue(result[0].isFavourite)
        XCTAssertEqual(result[0].logoURL?.absoluteString,
                       "http://jf.local:8096/Items/746bd1ff6d4432d20768254840f0acbc/Images/Primary?tag=c6273926e8951a56a888bfa92185676d")
        XCTAssertNil(result[0].streamURL, "resolved at play time")
        XCTAssertEqual(result[1].channelNumber, 5, "an OTA sub-channel sorts on its whole number")
        XCTAssertNil(result[1].logoURL)
        XCTAssertFalse(result[0].logoURL?.absoluteString.contains("tok") ?? true, "no token in image URLs")
    }

    // MARK: - Guide

    func test_guide_onePerChannelSortedWithJellyfinFields() async throws {
        server.respond("/LiveTv/Channels", body: channels)
        server.respond("/LiveTv/Programs", body: programs)
        let live = provider()
        let lineup = try await live.refreshChannels()
        let guide = try await live.fetchEPG(for: lineup, startDate: Date(), endDate: Date().addingTimeInterval(21600))

        let fox = try XCTUnwrap(guide[lineup[0].id])
        XCTAssertEqual(fox.map(\.title), ["Good Day Alabama 7a", "Live: Big Money in the Morning"])
        XCTAssertEqual(guide.count, 1, "programmes for channels outside the lineup are dropped")

        let show = fox[1]
        XCTAssertEqual(show.startTime, try Date("2026-10-21T10:00:00Z", strategy: .iso8601))
        XCTAssertEqual(show.endTime, try Date("2026-10-21T13:00:00Z", strategy: .iso8601))
        XCTAssertEqual(show.subtitle, "Fed Day")
        XCTAssertEqual(show.episodeNumber, "S1 E22")
        XCTAssertEqual(show.category, "Series, Bus./financial, News")
        XCTAssertTrue(show.isNew)
        XCTAssertTrue(show.isLiveAiring, "the guide's Live: marker")
        XCTAssertNotNil(show.iconURL)
        XCTAssertEqual(fox[0].category, "News", "no genres falls back to the flag")
        XCTAssertNil(fox[0].iconURL)

        // One request for the window, not one per channel.
        let guideRequests = server.requests.filter { $0.url!.path.hasSuffix("/LiveTv/Programs") }
        XCTAssertEqual(guideRequests.count, 1)
        let query = URLComponents(url: guideRequests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertNotNil(query.first { $0.name == "minEndDate" }?.value)
        XCTAssertNotNil(query.first { $0.name == "maxStartDate" }?.value)
    }

    // MARK: - Playback

    func test_resolve_opensTheLiveStreamAndPlaysTheStaticStream() async throws {
        server.respond("/LiveTv/Channels", body: channels)
        server.respond("/PlaybackInfo", body: playbackInfo)
        let live = provider()
        let channel = try await live.refreshChannels()[0]
        let resolved = try await live.resolveStreamURL(for: channel)
        let url = try XCTUnwrap(resolved)

        let request = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(request.url?.path, "/Items/746bd1ff6d4432d20768254840f0acbc/PlaybackInfo")
        XCTAssertEqual(server.jsonBody(server.requests.count - 1)["AutoOpenLiveStream"] as? Bool, true)

        XCTAssertEqual(url.path, "/Videos/746bd1ff6d4432d20768254840f0acbc/stream.ts")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["static"], "true")
        XCTAssertEqual(query["mediaSourceId"], "4b60385fcaf0891c48a75fc26c573622")
        XCTAssertEqual(query["liveStreamId"], "e2329f_af999c_4b6038")
        XCTAssertEqual(query["playSessionId"], "bba53d2aa73f4c6cbf924e7a2f640ad8")
        XCTAssertEqual(query["ApiKey"], "tok")
    }

    func test_streamURL_fallsBackToTheTranscodeWhenDirectStreamIsRefused() throws {
        let info = try JellyfinJSON.decoder().decode(JFLivePlaybackInfo.self, from: Data(#"""
            {"MediaSources":[{"Id":"src","SupportsDirectStream":false,"LiveStreamId":"ls1",
              "TranscodingUrl":"/videos/abc/master.m3u8?MediaSourceId=src&PlaySessionId=ps&ApiKey=tok"}],
             "PlaySessionId":"ps"}
            """#.utf8))
        let url = try XCTUnwrap(info.streamURL(channelItemID: "abc", baseURL: base, token: "tok"))
        XCTAssertEqual(url.path, "/videos/abc/master.m3u8")
        XCTAssertTrue(url.absoluteString.contains("LiveStreamId=ls1"))
    }

    func test_streamURL_nilWithoutAnOpenedLiveStream() throws {
        let info = try JellyfinJSON.decoder().decode(JFLivePlaybackInfo.self, from: Data(#"""
            {"MediaSources":[{"Id":"src","SupportsDirectStream":false}],"PlaySessionId":"ps"}
            """#.utf8))
        XCTAssertNil(info.streamURL(channelItemID: "abc", baseURL: base, token: "tok"))
    }

    // MARK: - Close

    func test_closeRequest_readsBaseTokenAndLiveStream() throws {
        let url = URL(string: "http://jf.local:8096/jellyfin/Videos/abc/stream.ts?static=true&liveStreamId=ls1&playSessionId=ps&ApiKey=tok")!
        let close = try XCTUnwrap(JellyfinLiveTVProvider.closeRequest(for: url))
        XCTAssertEqual(close.base.absoluteString, "http://jf.local:8096/jellyfin")
        XCTAssertEqual(close.token, "tok")
        XCTAssertEqual(close.liveStreamId, "ls1")
        XCTAssertNil(close.transcodeSession, "a static stream has no encode to stop")

        let hls = URL(string: "http://jf.local:8096/videos/abc/master.m3u8?LiveStreamId=ls1&PlaySessionId=ps&ApiKey=tok")!
        XCTAssertEqual(JellyfinLiveTVProvider.closeRequest(for: hls)?.transcodeSession, "ps")
    }

    func test_closeRequest_ignoresOtherServers() {
        XCTAssertNil(JellyfinLiveTVProvider.closeRequest(for: URL(string: "http://dispatcharr:9191/proxy/ts/stream/x")!))
        XCTAssertNil(JellyfinLiveTVProvider.closeRequest(
            for: URL(string: "http://pms:32400/livetv/sessions/u/c/index.m3u8?X-Plex-Token=t")!))
    }

    /// Jellyfin counts consumers: every open needs exactly one close, so a
    /// second stop must not close again (it would end someone else's stream).
    func test_keepalive_releasesAnOtherServerSessionOncePerStart() {
        var released: [URL] = []
        PlexLiveTimelineKeepalive.releaseOtherSession = { released.append($0) }
        defer { PlexLiveTimelineKeepalive.releaseOtherSession = nil }
        let url = URL(string: "http://jf.local:8096/Videos/abc/stream.ts?liveStreamId=ls1&ApiKey=tok")!

        let keepalive = PlexLiveTimelineKeepalive(transport: { _ in })
        keepalive.start(url: url)
        keepalive.stop()
        keepalive.stop()
        XCTAssertEqual(released, [url])

        PlexLiveTimelineKeepalive.release(url)
        XCTAssertEqual(released, [url, url], "an abandoned resolve is released too")
    }

    // MARK: - Automatic sources

    func test_serverSource_replacesRemovesAndIsNeverSaved() async throws {
        let store = LiveTVDataStore.shared
        let first = StubLiveSource(sourceId: "jellyfin:a")
        store.setServerSource(first, of: .jellyfin)
        XCTAssertTrue(store.hasSource(id: "jellyfin:a"))

        // Another server's sign-in takes its place.
        store.setServerSource(StubLiveSource(sourceId: "jellyfin:b"), of: .jellyfin)
        XCTAssertFalse(store.hasSource(id: "jellyfin:a"))
        XCTAssertTrue(store.hasSource(id: "jellyfin:b"))

        let saved = UserDefaults.standard.data(forKey: "liveTVSourceConfigurations").flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        XCTAssertFalse(saved.contains("jellyfin"))

        store.setServerSource(nil, of: .jellyfin)
        XCTAssertFalse(store.hasSource(id: "jellyfin:b"))
        XCTAssertFalse(store.channels.contains { $0.sourceType == .jellyfin })
    }

    func test_followsServer_onlyForMediaServers() {
        XCTAssertEqual(LiveTVSourceType.allCases.filter(\.followsServer), [.plex, .jellyfin])
    }

    func test_plexSourceKey_needsServerAndToken() {
        XCTAssertNil(LiveTVDataStore.plexSourceKey(serverURL: "http://pms:32400", token: nil))
        XCTAssertNil(LiveTVDataStore.plexSourceKey(serverURL: nil, token: "t"))
        XCTAssertNotEqual(LiveTVDataStore.plexSourceKey(serverURL: "http://pms:32400", token: "owner"),
                          LiveTVDataStore.plexSourceKey(serverURL: "http://pms:32400", token: "kid"),
                          "a profile switch on the same server finds the DVR again")
    }
}

private final class StubLiveSource: LiveTVProvider, @unchecked Sendable {
    let sourceType: LiveTVSourceType = .jellyfin
    let sourceId: String
    let displayName = "Stub"
    init(sourceId: String) { self.sourceId = sourceId }
    var isConnected: Bool { true }
    func fetchChannels() async throws -> [UnifiedChannel] { [] }
    func refreshChannels() async throws -> [UnifiedChannel] { [] }
    func fetchEPG(for channels: [UnifiedChannel], startDate: Date,
                  endDate: Date) async throws -> [String: [UnifiedProgram]] { [:] }
    func getCurrentProgram(for channel: UnifiedChannel) async -> UnifiedProgram? { nil }
    func buildStreamURL(for channel: UnifiedChannel) -> URL? { nil }
}
