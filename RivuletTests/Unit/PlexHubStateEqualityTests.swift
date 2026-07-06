//
//  PlexHubStateEqualityTests.swift
//  RivuletTests
//
//  Regression coverage for the Continue Watching "stale progress bar" bug:
//  the hub-equality check that gates whether `PlexDataStore` re-publishes a
//  refreshed hub must treat a changed `viewOffset` / `viewCount` as a change,
//  not just a changed set of ratingKeys. Comparing ratingKeys alone froze the
//  Continue Watching row's progress bars after playback.
//

import XCTest
@testable import Rivulet

final class PlexHubStateEqualityTests: XCTestCase {

    private func meta(_ ratingKey: String, viewOffset: Int? = nil, viewCount: Int? = nil) -> PlexMetadata {
        var m = PlexMetadata()
        m.ratingKey = ratingKey
        m.viewOffset = viewOffset
        m.viewCount = viewCount
        return m
    }

    func test_sameKeys_sameOffsets_areEqual() {
        let a = [meta("1", viewOffset: 1000), meta("2", viewOffset: 2000)]
        let b = [meta("1", viewOffset: 1000), meta("2", viewOffset: 2000)]
        XCTAssertTrue(PlexHub.metadataStateEqual(a, b))
    }

    // The core regression: same items, one has progressed. Must be NOT equal so
    // the row re-renders its progress bar.
    func test_sameKeys_changedOffset_areNotEqual() {
        let a = [meta("1", viewOffset: 1000)]
        let b = [meta("1", viewOffset: 5000)]
        XCTAssertFalse(PlexHub.metadataStateEqual(a, b))
    }

    // Marking watched changes viewCount even if offset is unchanged/reset.
    func test_sameKeys_changedViewCount_areNotEqual() {
        let a = [meta("1", viewOffset: 0, viewCount: 0)]
        let b = [meta("1", viewOffset: 0, viewCount: 1)]
        XCTAssertFalse(PlexHub.metadataStateEqual(a, b))
    }

    func test_differentKeys_areNotEqual() {
        let a = [meta("1"), meta("2")]
        let b = [meta("1"), meta("3")]
        XCTAssertFalse(PlexHub.metadataStateEqual(a, b))
    }

    func test_differentCounts_areNotEqual() {
        let a = [meta("1"), meta("2")]
        let b = [meta("1")]
        XCTAssertFalse(PlexHub.metadataStateEqual(a, b))
    }

    // Reorder (Plex moves the just-watched item to the front) is a change.
    func test_reorder_isNotEqual() {
        let a = [meta("1"), meta("2")]
        let b = [meta("2"), meta("1")]
        XCTAssertFalse(PlexHub.metadataStateEqual(a, b))
    }

    func test_bothNil_areEqual() {
        XCTAssertTrue(PlexHub.metadataStateEqual(nil, nil))
    }

    func test_nilVersusEmpty_areEqual() {
        XCTAssertTrue(PlexHub.metadataStateEqual(nil, []))
    }
}
