//
//  PlexRelayTests.swift
//  RivuletTests
//
//  Tests for Plex relay-connection detection. A false positive here would
//  wrongly cap a directly reachable server to 480p, so the direct-connection
//  cases matter as much as the relay ones.
//

import XCTest
@testable import Rivulet

final class PlexRelayTests: XCTestCase {

    // MARK: - Relay endpoints (should be detected)

    func testDetectsRelayURL() {
        // Shape seen in production: <ip-dashes>.<hash>.plex.direct:8443
        let url = URL(string: "https://178-79-141-27.6278e200ff8e4a93bfd8914adbc90a4b.plex.direct:8443")!
        XCTAssertTrue(PlexRelay.isRelayURL(url))
    }

    func testDetectsRelayFromString() {
        let serverURL = "https://178-79-141-27.6278e200ff8e4a93bfd8914adbc90a4b.plex.direct:8443"
        XCTAssertTrue(PlexRelay.isRelayURL(serverURL))
    }

    func testDetectsRelayWithPathAndQuery() {
        // The serverURL threaded into the URL builder keeps its host and port.
        let url = URL(string: "https://a-b.hash.plex.direct:8443/video/:/transcode/universal/start.m3u8?foo=bar")!
        XCTAssertTrue(PlexRelay.isRelayURL(url))
    }

    // MARK: - Direct connections (must NOT be treated as relay)

    func testDirectPlexDirectOnRealPortIsNotRelay() {
        // A directly reachable server embeds its real port (default 32400),
        // not the relay's fixed 8443. This is the case that must never be capped.
        let url = URL(string: "https://192-168-0-3.fca450f91b2544c49748d047c1c5750d.plex.direct:32400")!
        XCTAssertFalse(PlexRelay.isRelayURL(url))
    }

    func testLocalHTTPIsNotRelay() {
        let url = URL(string: "http://192.168.1.100:32400")!
        XCTAssertFalse(PlexRelay.isRelayURL(url))
    }

    func testPlexDirectWithoutExplicitPortIsNotRelay() {
        // No explicit port resolves to the https default (443), not 8443.
        let url = URL(string: "https://a-b.hash.plex.direct")!
        XCTAssertFalse(PlexRelay.isRelayURL(url))
    }

    func testNonPlexDirectHostOn8443IsNotRelay() {
        // A reverse proxy on the common alt-HTTPS port 8443 is not a relay.
        let url = URL(string: "https://plex.example.com:8443")!
        XCTAssertFalse(PlexRelay.isRelayURL(url))
    }

    func testHostMerelyContainingPlexDirectIsNotRelay() {
        // hasSuffix, not contains: a spoofed host must not match.
        let url = URL(string: "https://plex.direct.example.com:8443")!
        XCTAssertFalse(PlexRelay.isRelayURL(url))
    }

    func testMalformedStringIsNotRelay() {
        XCTAssertFalse(PlexRelay.isRelayURL("not a url"))
        XCTAssertFalse(PlexRelay.isRelayURL(""))
    }
}
