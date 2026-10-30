import XCTest
@testable import Rivulet

@MainActor
final class SiloRequestsTests: XCTestCase {
    private func makeService(_ server: SiloAuthTestServer, owner: @escaping @Sendable () async -> Bool = { true }) -> SiloRequests {
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, profileID: "profile-a", transport: server.transport)
        let provider = SiloProvider(serverID: "server-a", displayName: "Synthetic", profileID: "profile-a", client: client)
        return SiloRequests(provider: provider, ownerIsCurrent: owner)
    }

    func testUnavailableCapabilityStopsSearchBeforeItLeavesClient() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/requests/status", [.init(body: #"{"requests_enabled":true,"state":"available","allowed":false}"#)])
        let service = makeService(server)
        do { _ = try await service.search("Synthetic Movie") ; XCTFail("Search should be gated") }
        catch SiloRequestsError.unavailable { }
        let calls = await server.requests()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.url?.path, "/api/v2/requests/status")
    }

    func testStaleAuthorityDiscardsStatus() async throws {
        let server = SiloAuthTestServer()
        let service = makeService(server, owner: { false })
        do { _ = try await service.status(); XCTFail("Stale owner should fail") }
        catch SiloRequestsError.staleAuthority { }
        let calls = await server.requests()
        XCTAssertTrue(calls.isEmpty)
    }

    func testCancelEligibilityRespectsSubmissionBoundary() throws {
        func record(_ status: String, _ outcome: String, targets: String) throws -> SiloRequestRecord {
            let json = """
            {"id":"synthetic-1","media_type":"movie","tmdb_id":123,"title":"Synthetic Movie",\
            "status":"\(status)","outcome":"\(outcome)","created_at":"2026-01-01T00:00:00Z",\
            "updated_at":"2026-01-01T00:00:00Z","targets":\(targets)}
            """
            return try SiloJSON.decoder().decode(SiloRequestRecord.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try record("pending", "active", targets: "[]").canCancel)
        XCTAssertTrue(try record("approved", "active", targets: "[]").canCancel)
        XCTAssertFalse(try record("approved", "active", targets: #"[{"status":"queued"}]"#).canCancel)
        XCTAssertFalse(try record("queued", "active", targets: "[]").canCancel)
        XCTAssertFalse(try record("completed", "active", targets: "[]").canCancel)
        XCTAssertFalse(try record("pending", "cancelled", targets: "[]").canCancel)
        XCTAssertFalse(try record("approved", "active", targets: "null").canCancel)
    }

    func testFollowRequiresExplicitViewerPermissionState() throws {
        func state(_ following: String, viewer: String) throws -> SiloRequestState {
            let json = """
            {"requestable":false,"request_id":"synthetic-1","following":\(following),"requested_by_viewer":\(viewer)}
            """
            return try SiloJSON.decoder().decode(SiloRequestState.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try state("false", viewer: "false").canFollow)
        XCTAssertTrue(try state("true", viewer: "false").canUnfollow)
        XCTAssertFalse(try state("null", viewer: "false").canFollow)
        XCTAssertFalse(try state("false", viewer: "true").canFollow)
        XCTAssertFalse(try state("true", viewer: "true").canUnfollow)
    }

    func testCancelRefusesSubmittedRequestBeforeMutation() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/requests/status", [.init(body: #"{"requests_enabled":true,"state":"available","allowed":true}"#)])
        let json = #"{"id":"synthetic-1","media_type":"movie","tmdb_id":123,"title":"Synthetic Movie","status":"approved","outcome":"active","targets":[{"status":"queued"}],"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}"#
        let record = try SiloJSON.decoder().decode(SiloRequestRecord.self, from: Data(json.utf8))
        do { _ = try await makeService(server).cancel(record); XCTFail("Submitted request should be refused") }
        catch SiloRequestsError.notPermitted { }
        let calls = await server.requests()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.httpMethod, "GET")
    }
}
