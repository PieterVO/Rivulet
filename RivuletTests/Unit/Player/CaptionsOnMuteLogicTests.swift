// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class CaptionsOnMuteLogicTests: XCTestCase {
    private func track(_ id: Int, _ lang: String?, codec: String = "srt", forced: Bool = false) -> MediaTrack {
        MediaTrack(id: id, name: "t\(id)", language: nil, languageCode: lang, codec: codec, isForced: forced)
    }

    private lazy var tracks = [
        track(1, "eng", forced: true),
        track(2, "fra", codec: "pgs"),
        track(3, "fra"),
        track(4, "en"),
    ]

    func test_track_prefersSavedLanguage_textBeforeImage() {
        XCTAssertEqual(CaptionsOnMuteLogic.track(in: tracks, preferredLanguage: "fr", audioLanguage: "eng")?.id, 3)
    }

    func test_track_fallsBackToAudioLanguage_neverForced() {
        XCTAssertEqual(CaptionsOnMuteLogic.track(in: tracks, preferredLanguage: "deu", audioLanguage: "eng")?.id, 4)
    }

    func test_track_fallsBackToFirstFullTextTrack() {
        XCTAssertEqual(CaptionsOnMuteLogic.track(in: tracks, preferredLanguage: nil, audioLanguage: "jpn")?.id, 3)
        XCTAssertNil(CaptionsOnMuteLogic.track(in: [track(1, "eng", forced: true)], preferredLanguage: nil, audioLanguage: nil))
    }

    func test_activate_thenDeactivate_restoresOff() {
        var logic = CaptionsOnMuteLogic()
        XCTAssertEqual(logic.activate(current: nil, tracks: tracks, preferredLanguage: nil, audioLanguage: "eng"), 4)
        XCTAssertNil(logic.activate(current: tracks[3], tracks: tracks, preferredLanguage: nil, audioLanguage: "eng"))
        XCTAssertEqual(logic.deactivate(currentTrackId: 4), .some(nil))
    }

    func test_forcedTrackCountsAsOff_andIsRestored() {
        var logic = CaptionsOnMuteLogic()
        XCTAssertEqual(logic.activate(current: tracks[0], tracks: tracks, preferredLanguage: nil, audioLanguage: "eng"), 4)
        XCTAssertEqual(logic.deactivate(currentTrackId: 4), .some(1))
    }

    func test_userSubtitlesAlreadyOn_leftAlone() {
        var logic = CaptionsOnMuteLogic()
        XCTAssertNil(logic.activate(current: tracks[2], tracks: tracks, preferredLanguage: nil, audioLanguage: nil))
        XCTAssertEqual(logic.deactivate(currentTrackId: 3), nil as Int??)
    }

    func test_userPickDuringMute_winsAndIsNotReverted() {
        var logic = CaptionsOnMuteLogic()
        _ = logic.activate(current: nil, tracks: tracks, preferredLanguage: nil, audioLanguage: "eng")
        logic.userPicked()
        XCTAssertNil(logic.activate(current: nil, tracks: tracks, preferredLanguage: nil, audioLanguage: "eng"))
        XCTAssertEqual(logic.deactivate(currentTrackId: nil), nil as Int??)
        // The next mute starts fresh.
        XCTAssertEqual(logic.activate(current: nil, tracks: tracks, preferredLanguage: nil, audioLanguage: "eng"), 4)
    }

    func test_trackChangedOutsideThePicker_notReverted() {
        var logic = CaptionsOnMuteLogic()
        _ = logic.activate(current: nil, tracks: tracks, preferredLanguage: nil, audioLanguage: "eng")
        XCTAssertEqual(logic.deactivate(currentTrackId: 3), nil as Int??)
    }

    func test_noTracksYet_retriesWhenTheyArrive() {
        var logic = CaptionsOnMuteLogic()
        XCTAssertNil(logic.activate(current: nil, tracks: [], preferredLanguage: nil, audioLanguage: nil))
        XCTAssertEqual(logic.activate(current: nil, tracks: tracks, preferredLanguage: nil, audioLanguage: nil), 3)
    }

    func test_languageOfIntent() {
        XCTAssertEqual(CaptionsOnMuteLogic.language(of: .track(language: "spa", forced: false, hearingImpaired: false, codec: nil)), "spa")
        XCTAssertNil(CaptionsOnMuteLogic.language(of: .off))
        XCTAssertNil(CaptionsOnMuteLogic.language(of: nil))
    }
}
