import XCTest
@testable import Rivulet

@MainActor
final class SiloPeopleTests: XCTestCase {
    private func service(_ server: SiloAuthTestServer, owner: @escaping @Sendable () async -> Bool = { true }) -> SiloPeople {
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, profileID: "profile-a", transport: server.transport)
        return SiloPeople(provider: SiloProvider(serverID: "server-a", displayName: "Synthetic", profileID: "profile-a", client: client), ownerIsCurrent: owner)
    }

    func testCapabilityGatePreventsPeopleRead() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/catalog/search/capabilities", [.init(body: #"{"state":"available","allowed":true,"people_media_scope":false}"#)])
        do { _ = try await service(server).search("Example"); XCTFail("People must be gated") }
        catch SiloPeopleError.unavailable { }
        let calls = await server.requests()
        XCTAssertEqual(calls.count, 1)
    }

    func testOpaquePersonIdentityAndMediaScope() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/catalog/search/capabilities", [.init(body: #"{"state":"available","allowed":true,"people_media_scope":true}"#)])
        await server.respond("GET", "/api/v2/catalog/people", [.init(body: #"{"items":[{"id":"native:actor/01","name":"Example Actor"}]}"#)])
        let people = try await service(server).search("Example", mediaScope: "video")
        XCTAssertEqual(people.map(\.id), ["native:actor/01"])
        let requests = await server.requests()
        XCTAssertEqual(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "media_scope" })?.value, "video")
    }

    func testStaleAuthorityPreventsRequest() async throws {
        let server = SiloAuthTestServer()
        do { _ = try await service(server, owner: { false }).detail(personID: "opaque"); XCTFail("Stale owner") }
        catch SiloPeopleError.staleAuthority { }
        let calls = await server.requests()
        XCTAssertTrue(calls.isEmpty)
    }

    func testInvalidMediaScopeNeverHitsPeopleEndpoint() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/catalog/search/capabilities", [.init(body: #"{"state":"available","allowed":true,"people_media_scope":true}"#)])
        do { _ = try await service(server).search("Example", mediaScope: "video_with_episodes"); XCTFail("Missing capability") }
        catch SiloPeopleError.invalidScope { }
        let calls = await server.requests()
        XCTAssertEqual(calls.count, 1)
    }
}
