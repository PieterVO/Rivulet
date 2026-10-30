// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class SiloDiscoveryTests: XCTestCase {
    func testDiscoverUsesInlineRecommendationsAndPinsForYouWithoutExpandingSections() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/recommendations/discover", [.init(body: """
        {"items":[
          {"type":"genre_sampler","title":"Because you enjoy Adventure","kind":"genre","key":"Adventure",
           "items":[{"content_id":"movie:voyage","type":"movie","title":"The Voyage","genres":["Adventure"],"keywords":[],"status":"matched"}]},
          {"type":"popular","title":"Popular","kind":"popular","items":[]},
          {"type":"cluster","title":"FOR YOU","kind":"for-you-main",
           "items":[{"content_id":"series:orbit","type":"series","title":"Orbit","genres":[],"keywords":[],"status":"matched"}]},
          {"type":"recently_added","title":"Recently Added","kind":"recently-added",
           "items":[{"content_id":"movie:comet","type":"movie","title":"Comet","genres":[],"keywords":[],"status":"matched"}]}
        ],"page":{"has_more":false,"next_cursor":null}}
        """)])
        // The native Apple feed does not depend on these separate browse routes.
        for kind in ["genre", "popular", "for-you-main", "recently-added"] {
            await server.respond("GET", "/api/v2/recommendations/section/\(kind)", [.init(status: 503)])
        }
        let provider = provider(server)
        let result = try await provider.discoveryHubs()
        let hubs = try XCTUnwrap(result)
        XCTAssertEqual(hubs.map(\.title), ["FOR YOU", "Because you enjoy Adventure", "Recently Added"])
        XCTAssertEqual(hubs.flatMap(\.items).map(\.ref.itemID), ["series:orbit", "movie:voyage", "movie:comet"])
        XCTAssertTrue(hubs.flatMap(\.items).allSatisfy { $0.ref.providerID == provider.id })
        XCTAssertTrue(hubs.allSatisfy { !$0.canBrowse && $0.nextPage == nil })
        let requests = await server.requests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/v2/recommendations/discover"])
    }

    func testDiscoverRejectsIncompleteNativeCollectionsInsteadOfShowingPartialRows() async throws {
        for page in [#"{"has_more":true,"next_cursor":null}"#,
                     #"{"has_more":false,"next_cursor":"opaque-next"}"#] {
            let server = SiloAuthTestServer()
            await server.respond("GET", "/api/v2/recommendations/discover", [.init(body: """
            {"items":[{"type":"cluster","title":"For You",
              "items":[{"content_id":"movie:voyage","type":"movie","title":"The Voyage","genres":[],"keywords":[],"status":"matched"}]}],"page":\(page)}
            """)])
            do {
                _ = try await provider(server).discoveryHubs()
                XCTFail("An incomplete recommendations collection must not appear as a complete feed.")
            } catch let error as MediaProviderError {
                guard case .backendSpecific = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testCompleteEmptyNativeFeedRemainsSupportedWithoutInventedRecommendations() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/recommendations/discover", [.init(body: """
        {"items":[{"type":"popular","title":"Popular","items":[]}],
         "page":{"has_more":false,"next_cursor":""}}
        """)])
        let result = try await provider(server).discoveryHubs()
        let hubs = try XCTUnwrap(result)
        XCTAssertEqual(hubs.map(\.id), [])
    }

    func testNativeRecommendationsSurviveAnUnsupportedProviderAndAnotherServersFailureWithoutPlex() async throws {
        let registry = MediaProviderRegistry.shared
        let savedProviders = Array(registry.providers.values)
        let savedPlexID = registry.plexProvider?.id
        let auth = PlexAuthManager.shared
        let savedToken = auth.authToken
        auth.authToken = nil
        for id in registry.providers.keys { registry.unregister(providerID: id) }
        defer {
            for id in Array(registry.providers.keys) { registry.unregister(providerID: id) }
            for provider in savedProviders { registry.register(provider) }
            if let primary = savedProviders.first(where: { $0.id == savedPlexID }) { registry.register(primary) }
            auth.authToken = savedToken
        }
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/recommendations/discover", [.init(body: """
        {"items":[{"type":"cluster","title":"For You","items":[
          {"content_id":"movie:voyage","type":"movie","title":"The Voyage","genres":[],"keywords":[],"status":"matched"}
        ]}]}
        """)])
        let failedServer = SiloAuthTestServer()
        await failedServer.respond("GET", "/api/v2/recommendations/discover", [.init(status: 503)])
        let identity = UUID().uuidString
        let available = provider(server, serverID: "available-\(identity)")
        let failed = provider(failedServer, serverID: "failed-\(identity)")
        let unsupported = StubMediaProvider(id: "jellyfin:unsupported-\(identity)", kind: .jellyfin)
        registry.register(available)
        registry.register(failed)
        registry.register(unsupported)

        let model = DiscoverViewModel()
        await model.load()

        XCTAssertEqual(model.nativeSupportedProviders, [available.id])
        XCTAssertEqual(Set(model.nativeErrors.keys), [failed.id])
        XCTAssertEqual(model.nativeHubs.map(\.providerID), [available.id])
        XCTAssertEqual(model.nativeHubs.flatMap(\.items).map(\.ref.itemID), ["movie:voyage"])
        XCTAssertTrue(model.sectionItems.isEmpty, "A Silo-only feed must not depend on Plex's curated sections.")
        XCTAssertFalse(model.loading)
    }

    private func provider(_ server: SiloAuthTestServer, serverID: String = "discovery-server") -> SiloProvider {
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, profileID: "discovery-profile",
                                transport: server.transport)
        return SiloProvider(serverID: serverID, displayName: "Silo", profileID: "discovery-profile", client: client)
    }
}
