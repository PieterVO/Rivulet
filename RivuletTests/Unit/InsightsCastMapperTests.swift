// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class InsightsCastMapperTests: XCTestCase {

    func testTMDBMappingBuildsProfileURLAndCharacterRole() {
        let credit = TMDBCredit(id: 1, name: "Ellen Page", job: nil, department: nil,
                                character: "Ariadne", profilePath: "/abc.jpg")
        let people = InsightsCastMapper.mediaPeople(fromTMDB: [credit], titleTmdbId: 27205, titleIsMovie: true)
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].name, "Ellen Page")
        XCTAssertEqual(people[0].role, "Ariadne")
        XCTAssertEqual(people[0].imageURL?.absoluteString, "https://image.tmdb.org/t/p/w342/abc.jpg")
        XCTAssertEqual(people[0].titleTmdbId, 27205)
        XCTAssertTrue(people[0].titleIsMovie)
    }

    func testTMDBMappingDropsNamelessAndHandlesNilProfile() {
        let nameless = TMDBCredit(id: 2, name: nil, job: nil, department: nil, character: "X", profilePath: nil)
        let noPhoto = TMDBCredit(id: 3, name: "Someone", job: nil, department: nil, character: nil, profilePath: nil)
        let people = InsightsCastMapper.mediaPeople(fromTMDB: [nameless, noPhoto], titleTmdbId: 1, titleIsMovie: false)
        XCTAssertEqual(people.count, 1)
        XCTAssertNil(people[0].imageURL)
    }

    func testPlexAbsoluteThumbPassesThroughUnchanged() {
        // Plex person thumbs are often absolute metadata-CDN URLs; concatenating
        // serverURL onto them breaks the URL.
        let url = InsightsCastMapper.personThumbURL(
            "https://metadata-static.plex.tv/people/x.jpg",
            serverURL: "http://127.0.0.1:32400", authToken: "tok")
        XCTAssertEqual(url?.absoluteString, "https://metadata-static.plex.tv/people/x.jpg")
    }

    func testPlexRelativeThumbGetsServerAndToken() {
        let url = InsightsCastMapper.personThumbURL(
            "/library/metadata/1/thumb/2",
            serverURL: "http://127.0.0.1:32400", authToken: "tok")
        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:32400/library/metadata/1/thumb/2?X-Plex-Token=tok")
    }
}
