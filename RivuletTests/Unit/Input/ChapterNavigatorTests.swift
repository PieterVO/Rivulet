// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class ChapterNavigatorTests: XCTestCase {
    let starts: [TimeInterval] = [0, 300, 900, 1800]

    func testForwardSnapsToNextStart() {
        XCTAssertEqual(ChapterNavigator.snapTarget(from: 100, chapterStarts: starts, forward: true), 300)
        XCTAssertEqual(ChapterNavigator.snapTarget(from: 300, chapterStarts: starts, forward: true), 900)
    }

    func testForwardAtLastChapterReturnsNil() {
        XCTAssertNil(ChapterNavigator.snapTarget(from: 1900, chapterStarts: starts, forward: true))
    }

    func testBackwardSnapsToPreviousStart() {
        XCTAssertEqual(ChapterNavigator.snapTarget(from: 1000, chapterStarts: starts, forward: false), 900)
        // Just past a boundary goes to the PREVIOUS chapter, not back to
        // the same boundary (2s grace, like track-skip in music apps).
        XCTAssertEqual(ChapterNavigator.snapTarget(from: 901, chapterStarts: starts, forward: false), 300)
    }

    func testEmptyChaptersReturnsNil() {
        XCTAssertNil(ChapterNavigator.snapTarget(from: 100, chapterStarts: [], forward: true))
    }
}
