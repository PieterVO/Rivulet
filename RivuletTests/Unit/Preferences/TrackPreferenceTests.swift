//
//  TrackPreferenceTests.swift
//  RivuletTests
//
//  Unit tests for SubtitlePreferenceManager and AudioPreferenceManager
//

import XCTest
@testable import Rivulet

final class TrackPreferenceTests: XCTestCase {

    // MARK: - Subtitle Preference Tests

    func testSubtitleFindBestMatchReturnsNilWhenDisabled() {
        let tracks = [
            MediaTrack(id: 1, name: "English", languageCode: "eng", codec: "srt"),
            MediaTrack(id: 2, name: "Spanish", languageCode: "spa", codec: "srt")
        ]
        let preference = SubtitlePreference.off

        let result = SubtitlePreferenceManager.findBestMatch(in: tracks, preference: preference)

        XCTAssertNil(result)
    }

    func testSubtitleFindBestMatchReturnsNilForNoLanguageMatch() {
        let tracks = [
            MediaTrack(id: 1, name: "French", languageCode: "fra", codec: "srt"),
            MediaTrack(id: 2, name: "German", languageCode: "deu", codec: "srt")
        ]
        let preference = SubtitlePreference(enabled: true, languageCode: "eng", codec: "srt", preferHearingImpaired: false)

        let result = SubtitlePreferenceManager.findBestMatch(in: tracks, preference: preference)

        XCTAssertNil(result)
    }

    func testSubtitleFindBestMatchPrefersExactCodecMatch() {
        let tracks = [
            MediaTrack(id: 1, name: "English SRT", languageCode: "eng", codec: "srt"),
            MediaTrack(id: 2, name: "English PGS", languageCode: "eng", codec: "pgs"),
            MediaTrack(id: 3, name: "English ASS", languageCode: "eng", codec: "ass")
        ]
        let preference = SubtitlePreference(enabled: true, languageCode: "eng", codec: "pgs", preferHearingImpaired: false)

        let result = SubtitlePreferenceManager.findBestMatch(in: tracks, preference: preference)

        XCTAssertEqual(result?.id, 2)
        XCTAssertEqual(result?.codec, "pgs")
    }

    func testSubtitleFindBestMatchPrefersHearingImpairedWhenSet() {
        let tracks = [
            MediaTrack(id: 1, name: "English", languageCode: "eng", codec: "srt", isHearingImpaired: false),
            MediaTrack(id: 2, name: "English SDH", languageCode: "eng", codec: "srt", isHearingImpaired: true)
        ]
        let preference = SubtitlePreference(enabled: true, languageCode: "eng", codec: "srt", preferHearingImpaired: true)

        let result = SubtitlePreferenceManager.findBestMatch(in: tracks, preference: preference)

        XCTAssertEqual(result?.id, 2)
        XCTAssertTrue(result?.isHearingImpaired ?? false)
    }

    func testSubtitleFindBestMatchFallsBackToCodecWithoutHIPreference() {
        let tracks = [
            MediaTrack(id: 1, name: "English SRT", languageCode: "eng", codec: "srt", isHearingImpaired: false),
            MediaTrack(id: 2, name: "English PGS", languageCode: "eng", codec: "pgs", isHearingImpaired: false)
        ]
        // Wants PGS with HI, but no HI tracks exist
        let preference = SubtitlePreference(enabled: true, languageCode: "eng", codec: "pgs", preferHearingImpaired: true)

        let result = SubtitlePreferenceManager.findBestMatch(in: tracks, preference: preference)

        XCTAssertEqual(result?.id, 2)
        XCTAssertEqual(result?.codec, "pgs")
    }

    func testSubtitleFindBestMatchFallsBackToLanguageOnly() {
        let tracks = [
            MediaTrack(id: 1, name: "English SRT", languageCode: "eng", codec: "srt"),
            MediaTrack(id: 2, name: "French SRT", languageCode: "fra", codec: "srt")
        ]
        // Wants ASS codec which doesn't exist
        let preference = SubtitlePreference(enabled: true, languageCode: "eng", codec: "ass", preferHearingImpaired: false)

        let result = SubtitlePreferenceManager.findBestMatch(in: tracks, preference: preference)

        XCTAssertEqual(result?.id, 1)
        XCTAssertEqual(result?.languageCode, "eng")
    }

    func testSubtitleFindBestMatchFallsBackToHIPreferenceWhenNoCodecMatch() {
        let tracks = [
            MediaTrack(id: 1, name: "English", languageCode: "eng", codec: "srt", isHearingImpaired: false),
            MediaTrack(id: 2, name: "English SDH", languageCode: "eng", codec: "srt", isHearingImpaired: true)
        ]
        // Wants ASS with HI, ASS doesn't exist, should fall back to SRT with HI
        let preference = SubtitlePreference(enabled: true, languageCode: "eng", codec: "ass", preferHearingImpaired: true)

        let result = SubtitlePreferenceManager.findBestMatch(in: tracks, preference: preference)

        XCTAssertEqual(result?.id, 2)
        XCTAssertTrue(result?.isHearingImpaired ?? false)
    }

    func testSubtitleFindBestMatchReturnsFirstLanguageMatchAsFinalFallback() {
        let tracks = [
            MediaTrack(id: 1, name: "English 1", languageCode: "eng", codec: "srt", isHearingImpaired: false),
            MediaTrack(id: 2, name: "English 2", languageCode: "eng", codec: "pgs", isHearingImpaired: false)
        ]
        // Wants HI but no HI tracks exist, no specific codec, should get first match
        let preference = SubtitlePreference(enabled: true, languageCode: "eng", codec: nil, preferHearingImpaired: true)

        let result = SubtitlePreferenceManager.findBestMatch(in: tracks, preference: preference)

        XCTAssertEqual(result?.id, 1)
    }

    func testSubtitlePreferenceInitFromTrack() {
        let track = MediaTrack(
            id: 1,
            name: "English SDH",
            languageCode: "eng",
            codec: "pgs",
            isHearingImpaired: true
        )

        let preference = SubtitlePreference(from: track)

        XCTAssertTrue(preference.enabled)
        XCTAssertEqual(preference.languageCode, "eng")
        XCTAssertEqual(preference.codec, "pgs")
        XCTAssertTrue(preference.preferHearingImpaired)
    }

    // MARK: - Audio Preference Tests

    func testAudioFindBestMatchReturnsNilForEmptyTracks() {
        let tracks: [MediaTrack] = []
        let preference = AudioPreference(languageCode: "eng")

        let result = AudioPreferenceManager.findBestMatch(in: tracks, preference: preference)

        XCTAssertNil(result)
    }

    func testAudioFindBestMatchPrefersPreferredLanguage() {
        let tracks = [
            MediaTrack(id: 1, name: "English", languageCode: "eng", channels: 6),
            MediaTrack(id: 2, name: "Spanish", languageCode: "spa", channels: 6),
            MediaTrack(id: 3, name: "French", languageCode: "fra", channels: 6)
        ]
        let preference = AudioPreference(languageCode: "spa")

        let result = AudioPreferenceManager.findBestMatch(in: tracks, preference: preference)

        XCTAssertEqual(result?.id, 2)
        XCTAssertEqual(result?.languageCode, "spa")
    }

    func testAudioFindBestMatchPrefersHighestChannelCount() {
        let tracks = [
            MediaTrack(id: 1, name: "English Stereo", languageCode: "eng", channels: 2),
            MediaTrack(id: 2, name: "English 5.1", languageCode: "eng", channels: 6),
            MediaTrack(id: 3, name: "English 7.1", languageCode: "eng", channels: 8)
        ]
        let preference = AudioPreference(languageCode: "eng")

        let result = AudioPreferenceManager.findBestMatch(in: tracks, preference: preference)

        XCTAssertEqual(result?.id, 3)
        XCTAssertEqual(result?.channels, 8)
    }

    func testAudioFindBestMatchFallsBackToEnglish() {
        let tracks = [
            MediaTrack(id: 1, name: "English", languageCode: "eng", channels: 6),
            MediaTrack(id: 2, name: "French", languageCode: "fra", channels: 6)
        ]
        // Prefer Japanese which doesn't exist
        let preference = AudioPreference(languageCode: "jpn")

        let result = AudioPreferenceManager.findBestMatch(in: tracks, preference: preference)

        XCTAssertEqual(result?.id, 1)
        XCTAssertEqual(result?.languageCode, "eng")
    }

    func testAudioFindBestMatchAcceptsVariousEnglishCodes() {
        // Test "en" code
        let tracksEn = [
            MediaTrack(id: 1, name: "English", languageCode: "en", channels: 6)
        ]
        let prefJpn = AudioPreference(languageCode: "jpn")

        let resultEn = AudioPreferenceManager.findBestMatch(in: tracksEn, preference: prefJpn)
        XCTAssertEqual(resultEn?.languageCode, "en")

        // Test "english" code
        let tracksEnglish = [
            MediaTrack(id: 1, name: "English", languageCode: "english", channels: 6)
        ]

        let resultEnglish = AudioPreferenceManager.findBestMatch(in: tracksEnglish, preference: prefJpn)
        XCTAssertEqual(resultEnglish?.languageCode, "english")
    }

    func testAudioFindBestMatchFallsBackToDefaultTrack() {
        let tracks = [
            MediaTrack(id: 1, name: "French", languageCode: "fra", channels: 6),
            MediaTrack(id: 2, name: "German", languageCode: "deu", isDefault: true, channels: 6)
        ]
        // No preferred language, no English
        let preference = AudioPreference(languageCode: "jpn")

        let result = AudioPreferenceManager.findBestMatch(in: tracks, preference: preference)

        XCTAssertEqual(result?.id, 2)
        XCTAssertTrue(result?.isDefault ?? false)
    }

    func testAudioFindBestMatchFallsBackToFirstTrack() {
        let tracks = [
            MediaTrack(id: 1, name: "French", languageCode: "fra", channels: 6),
            MediaTrack(id: 2, name: "German", languageCode: "deu", channels: 6)
        ]
        // No preferred language, no English, no default
        let preference = AudioPreference(languageCode: "jpn")

        let result = AudioPreferenceManager.findBestMatch(in: tracks, preference: preference)

        XCTAssertEqual(result?.id, 1)
    }

    func testAudioFindBestMatchIsCaseInsensitive() {
        let tracks = [
            MediaTrack(id: 1, name: "English", languageCode: "ENG", channels: 6)
        ]
        let preference = AudioPreference(languageCode: "eng")

        let result = AudioPreferenceManager.findBestMatch(in: tracks, preference: preference)

        XCTAssertEqual(result?.id, 1)
    }

    func testAudioPreferenceInitFromTrack() {
        let track = MediaTrack(
            id: 1,
            name: "Japanese",
            languageCode: "jpn",
            channels: 6
        )

        let preference = AudioPreference(from: track)

        XCTAssertEqual(preference.languageCode, "jpn")
    }

    func testAudioPreferenceDefaultEnglish() {
        let preference = AudioPreference.defaultEnglish

        XCTAssertEqual(preference.languageCode, "eng")
    }
}
