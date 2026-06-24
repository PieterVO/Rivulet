import XCTest
@testable import Rivulet

final class PersonItemMapperTests: XCTestCase {
    func test_buildsMetadataOnlyMovieItem() {
        let url = URL(string: "https://metadata-static.plex.tv/p/poster.jpg")!
        let item = PersonItemMapper.metadataOnlyItem(
            tmdbId: 1234, isMovie: true, title: "The Town", year: 2010,
            posterURL: url, overview: "Bank robbers.")
        XCTAssertTrue(item.isMetadataOnly)
        XCTAssertEqual(item.tmdbID, 1234)
        XCTAssertEqual(item.kind, .movie)
        XCTAssertEqual(item.title, "The Town")
        XCTAssertEqual(item.year, 2010)
        XCTAssertEqual(item.artwork.poster, url)
    }

    func test_buildsMetadataOnlyShowItem() {
        let item = PersonItemMapper.metadataOnlyItem(
            tmdbId: 99, isMovie: false, title: "Mad Men", year: 2007,
            posterURL: nil, overview: nil)
        XCTAssertEqual(item.kind, .show)
        XCTAssertEqual(item.tmdbID, 99)
        XCTAssertNil(item.artwork.poster)
    }
}
