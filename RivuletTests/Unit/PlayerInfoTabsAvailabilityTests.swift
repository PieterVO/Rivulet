// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerInfoTabsAvailabilityTests.swift
//  RivuletTests
//
//  Which tabs the Info popup offers. Info always; Description only with a
//  summary (#267); Advanced only on the aether route (a non-nil advanced-stats
//  provider). One tab means no tab bar, exactly as the popup rendered before.
//

import XCTest
@testable import Rivulet

@MainActor
final class PlayerInfoTabsAvailabilityTests: XCTestCase {

    func testDescriptionLeadsWhenAllTabsAvailable() {
        XCTAssertEqual(PlayerInfoTabsView.tabs(hasDescription: true, hasAdvanced: true),
                       [.description, .info, .advanced])
    }

    func testInfoOnlyWhenNeitherOptionalTabApplies() {
        XCTAssertEqual(PlayerInfoTabsView.tabs(hasDescription: false, hasAdvanced: false), [.info])
        XCTAssertFalse(PlayerInfoTabsView.showsTabBar(hasDescription: false, hasAdvanced: false))
    }

    func testTabBarShownForEitherOptionalTabAlone() {
        XCTAssertEqual(PlayerInfoTabsView.tabs(hasDescription: true, hasAdvanced: false), [.description, .info])
        XCTAssertEqual(PlayerInfoTabsView.tabs(hasDescription: false, hasAdvanced: true), [.info, .advanced])
        XCTAssertTrue(PlayerInfoTabsView.showsTabBar(hasDescription: true, hasAdvanced: false))
        XCTAssertTrue(PlayerInfoTabsView.showsTabBar(hasDescription: false, hasAdvanced: true))
    }

    // MARK: - Description content

    func testParagraphsDropsBlankLinesAndTrims() {
        XCTAssertEqual(CardDescriptionView.paragraphs(of: "  First line \n\n Second line "),
                       ["First line", "Second line"])
    }

    func testNoParagraphsForMissingOrBlankSummary() {
        XCTAssertTrue(CardDescriptionView.paragraphs(of: nil).isEmpty)
        XCTAssertTrue(CardDescriptionView.paragraphs(of: "   \n  ").isEmpty)
    }

    func testEpisodeContextLineUsesShowAndEpisodeNumber() {
        var episode = PlexMetadata()
        episode.type = "episode"
        episode.title = "The Pilot"
        episode.grandparentTitle = "Some Show"
        episode.parentIndex = 1
        episode.index = 5
        XCTAssertEqual(CardDescriptionView.contextLine(for: episode), "Some Show · S01E05")
    }

    func testMovieContextLineUsesYearRatingRuntime() {
        var movie = PlexMetadata()
        movie.type = "movie"
        movie.title = "Some Movie"
        movie.year = 1999
        movie.contentRating = "R"
        movie.duration = 90 * 60 * 1000
        XCTAssertEqual(CardDescriptionView.contextLine(for: movie), "1999 · R · 1h 30m")
    }

    func testContextLineNilWhenNothingKnown() {
        XCTAssertNil(CardDescriptionView.contextLine(for: PlexMetadata()))
    }
}
