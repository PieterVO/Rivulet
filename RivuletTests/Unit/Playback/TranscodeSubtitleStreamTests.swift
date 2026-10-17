import XCTest
@testable import Rivulet

final class TranscodeSubtitleStreamTests: XCTestCase {

    func test_dialogue_becomesTimedEventLine() throws {
        // As PMS sends an embedded ASS line: commas inside Text stay in Text.
        let event = try XCTUnwrap(TranscodeSubtitleStream.event(fromDialogue:
            #"Dialogue: 0,0:00:14.56,1:00:16.99,Narration,Go Gunhee,0,0,0,,The other side, \Nteemed"#))
        XCTAssertEqual(event.start, 14.56, accuracy: 0.0001)
        XCTAssertEqual(event.end, 3616.99, accuracy: 0.0001)
        XCTAssertEqual(event.line, #"0,0,Narration,Go Gunhee,0,0,0,,The other side, \Nteemed"#)
        XCTAssertEqual(ASSEventLine(event.line)?.plainText, "The other side, \nteemed")
    }

    func test_nonDialogueOrMalformed_isNil() {
        XCTAssertNil(TranscodeSubtitleStream.event(fromDialogue: "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"))
        XCTAssertNil(TranscodeSubtitleStream.event(fromDialogue: "Dialogue: 0,0:00:01.00,Default"))
    }

    func test_subtitlesURL_keepsQueryAndSwapsEndpoint() throws {
        let hls = try XCTUnwrap(URL(string:
            "http://10.0.0.2:32400/video/:/transcode/universal/start.m3u8?session=abc&offset=600&X-Plex-Client-Profile-Extra=a%2Bb"))
        let url = try XCTUnwrap(PlexNetworkManager.transcodeSubtitlesURL(forHLS: hls))
        XCTAssertEqual(url.absoluteString,
            "http://10.0.0.2:32400/video/:/transcode/universal/subtitles?session=abc&offset=600&X-Plex-Client-Profile-Extra=a%2Bb")
        XCTAssertNil(PlexNetworkManager.transcodeSubtitlesURL(forHLS: try XCTUnwrap(URL(string: "http://h/library/parts/1/file.mkv"))))
    }
}
