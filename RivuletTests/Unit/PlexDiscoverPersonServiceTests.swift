//
//  PlexDiscoverPersonServiceTests.swift
//  RivuletTests
//
//  TDD fixture test for PlexDiscoverPersonService.decode(personData:filmographyData:).
//  The fixture JSON matches the ASSUMED Discover shape; adjust in Task 4b after
//  confirming the live response via [PersonSpike] logs.
//

import XCTest
@testable import Rivulet

final class PlexDiscoverPersonServiceTests: XCTestCase {
    func test_decodesPersonAndFilmography() throws {
        let person = """
        {"MediaContainer":{"Metadata":[{"title":"Jon Hamm",
          "summary":"American actor.",
          "thumb":"https://metadata-static.plex.tv/p/people/abc.jpg"}]}}
        """.data(using: .utf8)!
        let films = """
        {"MediaContainer":{"Metadata":[
          {"type":"movie","title":"The Town","year":2010,
           "thumb":"https://metadata-static.plex.tv/p/t.jpg",
           "Guid":[{"id":"tmdb://1234"}]},
          {"type":"show","title":"Mad Men","year":2007,
           "Guid":[{"id":"tmdb://99"}]}
        ]}}
        """.data(using: .utf8)!
        let dto = try PlexDiscoverPersonService.decode(personData: person, filmographyData: films)
        XCTAssertEqual(dto.name, "Jon Hamm")
        XCTAssertEqual(dto.biography, "American actor.")
        XCTAssertEqual(dto.titles.count, 2)
        XCTAssertEqual(dto.titles[0].guids.first, "tmdb://1234")
        XCTAssertTrue(dto.titles[0].isMovie)
        XCTAssertFalse(dto.titles[1].isMovie)
    }
}
