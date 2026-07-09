import XCTest
@testable import Rivulet

final class TopShelfLogoResolverTests: XCTestCase {
    private let server = "http://plex.local:32400"
    private let token = "TESTTOKEN"

    func testSourceRatingKeyEpisodeUsesGrandparent() {
        var m = PlexMetadata()
        m.type = "episode"; m.ratingKey = "ep1"; m.grandparentRatingKey = "show1"
        XCTAssertEqual(TopShelfLogoResolver.sourceRatingKey(for: m), "show1")
    }

    func testSourceRatingKeyMovieUsesOwn() {
        var m = PlexMetadata()
        m.type = "movie"; m.ratingKey = "mv1"
        XCTAssertEqual(TopShelfLogoResolver.sourceRatingKey(for: m), "mv1")
    }

    func testLogoURLBuiltFromClearLogoPath() {
        var m = PlexMetadata()
        m.Image = [PlexImage(alt: nil, type: "clearLogo", url: "/library/metadata/1/clearLogo")]
        let s = TopShelfLogoResolver.logoURLString(from: m, serverURL: server, token: token)
        XCTAssertTrue(s.contains("/library/metadata/1/clearLogo"))
        XCTAssertTrue(s.contains("X-Plex-Token=\(token)"))
    }

    func testLogoURLEmptyWhenNoClearLogo() {
        let m = PlexMetadata()  // no Image array
        XCTAssertEqual(TopShelfLogoResolver.logoURLString(from: m, serverURL: server, token: token), "")
    }
}
