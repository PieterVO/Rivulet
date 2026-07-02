//
//  ChapterSegmentLayoutTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class ChapterSegmentLayoutTests: XCTestCase {

    private func chapter(startMs: Int, endMs: Int?, tag: String? = nil) -> PlexChapter {
        PlexChapter(id: nil, tag: tag, index: nil, startTimeOffset: startMs, endTimeOffset: endMs, thumb: nil)
    }

    func test_noChapters_isSingleFullWidthSegment() {
        let layout = ChapterSegmentLayout(chapters: [], duration: 100, width: 1006, height: 120, gap: 6)
        XCTAssertEqual(layout.segments.count, 1)
        XCTAssertEqual(layout.segments[0].rect, CGRect(x: 0, y: 0, width: 1006, height: 120))
        XCTAssertEqual(layout.segments[0].startTime, 0)
        XCTAssertEqual(layout.segments[0].endTime, 100)
    }

    func test_zeroDuration_isSingleFullWidthSegment() {
        let layout = ChapterSegmentLayout(chapters: [], duration: 0, width: 1006, height: 120, gap: 6)
        XCTAssertEqual(layout.segments.count, 1)
        XCTAssertEqual(layout.segments[0].rect.width, 1006)
    }

    func test_threeChapters_proportionalWidthsWithGaps() {
        // 0-30, 30-60, 60-100 (in seconds; source is ms).
        let chapters = [
            chapter(startMs: 0, endMs: 30_000, tag: "Opening"),
            chapter(startMs: 30_000, endMs: 60_000, tag: "Middle"),
            chapter(startMs: 60_000, endMs: 100_000, tag: "End"),
        ]
        let layout = ChapterSegmentLayout(chapters: chapters, duration: 100, width: 1006, height: 120, gap: 6)
        XCTAssertEqual(layout.segments.count, 3)

        let totalGap: CGFloat = 6 * 2
        let usable: CGFloat = 1006 - totalGap
        let seg0Width = usable * CGFloat(30.0 / 100.0)
        let seg1Width = usable * CGFloat(30.0 / 100.0)
        let seg2Width = usable * CGFloat(40.0 / 100.0)

        XCTAssertEqual(layout.segments[0].rect.minX, 0, accuracy: 0.01)
        XCTAssertEqual(layout.segments[0].rect.width, seg0Width, accuracy: 0.01)
        XCTAssertEqual(layout.segments[1].rect.minX, seg0Width + 6, accuracy: 0.01)
        XCTAssertEqual(layout.segments[1].rect.width, seg1Width, accuracy: 0.01)
        XCTAssertEqual(layout.segments[2].rect.minX, seg0Width + 6 + seg1Width + 6, accuracy: 0.01)
        XCTAssertEqual(layout.segments[2].rect.width, seg2Width, accuracy: 0.01)

        for t: TimeInterval in [0, 10, 29.9, 30, 65, 100] {
            XCTAssertEqual(layout.time(for: layout.x(for: t)), t, accuracy: 0.2)
        }
    }

    func test_chapterNotStartingAtZero_getsLeadingImplicitSegment() {
        // Plex sometimes omits the chapter opening — treat 0→first start as an implicit segment.
        let chapters = [chapter(startMs: 40_000, endMs: 100_000)]
        let layout = ChapterSegmentLayout(chapters: chapters, duration: 100, width: 1006, height: 120, gap: 6)
        XCTAssertEqual(layout.segments.count, 2)
        XCTAssertEqual(layout.segments[0].startTime, 0)
        XCTAssertEqual(layout.segments[0].endTime, 40)
    }
}
