// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// `VTTParser` is the only parser left with a production caller: the content
/// filter parses `text/mcf+vtt` documents with it, taking cue timings from here
/// and reading each cue's text as a filter directive. These cover what that
/// caller depends on.
///
/// The SRT and ASS parsers, and the `SubtitleFormat` factory, were deleted along
/// with the app-side subtitle pipeline — captions now come from AetherEngine, or
/// from AVPlayer's legible output on Live TV's remote-HLS path.
final class SubtitleParserTests: XCTestCase {

    func testParsesCueTimingsAndText() throws {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:04.500
        First line

        00:01:02.250 --> 00:01:05.000
        Second line
        """

        let track = try VTTParser().parse(vtt)

        XCTAssertEqual(track.cues.count, 2)
        XCTAssertEqual(track.cues[0].startTime, 1.0, accuracy: 0.001)
        XCTAssertEqual(track.cues[0].endTime, 4.5, accuracy: 0.001)
        XCTAssertEqual(track.cues[0].text, "First line")
        // Minutes must carry into seconds, which is where an off-by-60 would hide.
        XCTAssertEqual(track.cues[1].startTime, 62.25, accuracy: 0.001)
        XCTAssertEqual(track.cues[1].endTime, 65.0, accuracy: 0.001)
        XCTAssertEqual(track.cues[1].text, "Second line")
    }

    func testParsesHourTimestampsAndMultiLineCues() throws {
        let vtt = """
        WEBVTT

        01:02:03.500 --> 01:02:06.000
        category=violence
        channel=main
        """

        let track = try VTTParser().parse(vtt)

        XCTAssertEqual(track.cues.count, 1)
        XCTAssertEqual(track.cues[0].startTime, 3723.5, accuracy: 0.001)
        // The filter splits the payload across lines, so they have to survive.
        XCTAssertEqual(track.cues[0].text, "category=violence\nchannel=main")
    }

    func testSkipsCueIdentifiers() throws {
        let vtt = """
        WEBVTT

        cue-1
        00:00:02.000 --> 00:00:03.000
        Only this is text
        """

        let track = try VTTParser().parse(vtt)

        XCTAssertEqual(track.cues.count, 1)
        XCTAssertEqual(track.cues[0].text, "Only this is text")
    }

    func testEmptyDocumentYieldsNoCues() throws {
        let track = try VTTParser().parse("WEBVTT\n")
        XCTAssertTrue(track.cues.isEmpty)
    }
}
