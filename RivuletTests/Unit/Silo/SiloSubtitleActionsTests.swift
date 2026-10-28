// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class SiloSubtitleActionsTests: XCTestCase {
    func testUnavailableOrDeniedServerCapabilitiesDoNotExposeActions() {
        for state in ["disabled", "not_configured", "unsupported"] {
            let search = SiloSubtitleProviderStatus(enabled: true, providers: ["opensubtitles"], allowed: true, state: state)
            let ai = SiloSubtitleAIStatus(enabled: true, transcribeEnabled: true, allowed: true, state: state)
            XCTAssertFalse(search.canSearch, state)
            XCTAssertFalse(ai.canTranslate, state)
            XCTAssertFalse(ai.canTranscribe, state)
        }
        let denied = SiloSubtitleAIStatus(enabled: true, transcribeEnabled: true, allowed: false, state: "available")
        XCTAssertFalse(denied.canTranslate)
        XCTAssertFalse(denied.canTranscribe)
        let transcription = SiloSubtitleAIStatus(enabled: false, transcribeEnabled: true, allowed: true, state: "available")
        XCTAssertTrue(transcription.canTranscribe)
        XCTAssertFalse(transcription.canTranslate)
        let translation = SiloSubtitleAIStatus(enabled: true, transcribeEnabled: false, allowed: true, state: "available")
        XCTAssertTrue(translation.canTranslate)
        XCTAssertFalse(translation.canTranscribe)
    }

    func testTranslationEligibilityAndRequestIdentityUseTheActualTextSource() {
        func track(_ index: Int, codec: String, language: String) -> SubtitleTrack {
            SubtitleTrack(id: "file:file-a:subtitle:\(index)", index: index, codec: codec, language: language,
                          title: nil, extendedTitle: nil, isDefault: false, isForced: false, isHearingImpaired: false,
                          isEmbedded: true, externalURL: nil, isSelected: false, nativeStreamIndex: index + 14)
        }
        let source = MediaSource(id: "file-a", container: "mkv", duration: 600, bitrate: nil, fileSize: nil,
                                 fileName: nil, videoResolution: nil, videoTracks: [], audioTracks: [], subtitleTracks: [
                                    track(16, codec: "subrip", language: "eng"),
                                    track(17, codec: "hdmv_pgs_subtitle", language: "eng"),
                                    track(18, codec: "ass", language: "nld"),
                                    track(19, codec: "unknown", language: "eng")
                                 ], streamKind: .directPlay, streamURL: nil)
        let enabled = SiloSubtitleAIStatus(enabled: true, transcribeEnabled: false, allowed: true, state: "available")
        let options = enabled.generationOptions(for: source, targetLanguage: "nl")
        XCTAssertEqual(options.map(\.kind), [.translate])
        XCTAssertEqual(options.map(\.sourceIndex), [16], "the FFmpeg index is not a Silo AI source ordinal")
        XCTAssertEqual(options.map(\.targetLanguage), ["nl"])
        let disabled = SiloSubtitleAIStatus(enabled: false, transcribeEnabled: false, allowed: true, state: "available")
        XCTAssertTrue(disabled.generationOptions(for: source, targetLanguage: "nl").isEmpty)
    }

    func testOnlyPendingAndRunningJobsContinuePollingOrOfferCancellation() throws {
        for status in ["pending", "running", "completed", "failed", "cancelled", "unrecognized"] {
            let json = """
            {"id":"90071992547409931234","media_file_id":"file-a","kind":"translate","status":"\(status)",
             "progress":0.5,"progress_message":null,"result_subtitle_id":null,"error_message":null,
             "source_language":"en","target_language":"nl"}
            """
            let job = try SiloJSON.decoder().decode(SiloSubtitleAIJob.self, from: Data(json.utf8))
            let active = status == "pending" || status == "running"
            XCTAssertEqual(job.isActive, active, status)
            XCTAssertEqual(PlayerSubtitleOperation.job(job).cancellableJobID != nil, active, status)
        }
    }
}
