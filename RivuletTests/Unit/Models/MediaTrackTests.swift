//
//  MediaTrackTests.swift
//  RivuletTests
//
//  Unit tests for MediaTrack
//

import XCTest
@testable import Rivulet

final class MediaTrackTests: XCTestCase {

    // MARK: - Codec Formatting Tests

    func testFormattedCodecMapsAAC() {
        let track = MediaTrack(id: 1, name: "Track", codec: "aac")
        XCTAssertEqual(track.formattedCodec, "AAC")
    }

    func testFormattedCodecMapsAC3() {
        let track = MediaTrack(id: 1, name: "Track", codec: "ac3")
        XCTAssertEqual(track.formattedCodec, "AC3")

        let trackAlt = MediaTrack(id: 1, name: "Track", codec: "a_ac3")
        XCTAssertEqual(trackAlt.formattedCodec, "AC3")
    }

    func testFormattedCodecMapsEAC3() {
        let track = MediaTrack(id: 1, name: "Track", codec: "eac3")
        XCTAssertEqual(track.formattedCodec, "EAC3")

        let trackAlt = MediaTrack(id: 1, name: "Track", codec: "a_eac3")
        XCTAssertEqual(trackAlt.formattedCodec, "EAC3")
    }

    func testFormattedCodecMapsTrueHD() {
        let track = MediaTrack(id: 1, name: "Track", codec: "truehd")
        XCTAssertEqual(track.formattedCodec, "TrueHD")

        let trackAlt = MediaTrack(id: 1, name: "Track", codec: "a_truehd")
        XCTAssertEqual(trackAlt.formattedCodec, "TrueHD")
    }

    func testFormattedCodecMapsDTS() {
        let track = MediaTrack(id: 1, name: "Track", codec: "dts")
        XCTAssertEqual(track.formattedCodec, "DTS")

        let trackDCA = MediaTrack(id: 1, name: "Track", codec: "dca")
        XCTAssertEqual(trackDCA.formattedCodec, "DTS")
    }

    func testFormattedCodecMapsDTSHDMA() {
        let track = MediaTrack(id: 1, name: "Track", codec: "dts-hd ma")
        XCTAssertEqual(track.formattedCodec, "DTS-HD MA")

        let trackAlt = MediaTrack(id: 1, name: "Track", codec: "dtshd-ma")
        XCTAssertEqual(trackAlt.formattedCodec, "DTS-HD MA")
    }

    func testFormattedCodecMapsDTSHD() {
        let track = MediaTrack(id: 1, name: "Track", codec: "dtshd")
        XCTAssertEqual(track.formattedCodec, "DTS-HD")

        let trackAlt = MediaTrack(id: 1, name: "Track", codec: "dts-hd")
        XCTAssertEqual(trackAlt.formattedCodec, "DTS-HD")
    }

    func testFormattedCodecMapsFLAC() {
        let track = MediaTrack(id: 1, name: "Track", codec: "flac")
        XCTAssertEqual(track.formattedCodec, "FLAC")
    }

    func testFormattedCodecMapsOpus() {
        let track = MediaTrack(id: 1, name: "Track", codec: "opus")
        XCTAssertEqual(track.formattedCodec, "Opus")
    }

    func testFormattedCodecMapsMP3() {
        let track = MediaTrack(id: 1, name: "Track", codec: "mp3")
        XCTAssertEqual(track.formattedCodec, "MP3")

        let trackMP2 = MediaTrack(id: 1, name: "Track", codec: "mp2")
        XCTAssertEqual(trackMP2.formattedCodec, "MP3")
    }

    func testFormattedCodecMapsLPCM() {
        let track = MediaTrack(id: 1, name: "Track", codec: "pcm")
        XCTAssertEqual(track.formattedCodec, "LPCM")

        let trackLPCM = MediaTrack(id: 1, name: "Track", codec: "lpcm")
        XCTAssertEqual(trackLPCM.formattedCodec, "LPCM")
    }

    func testFormattedCodecMapsVorbis() {
        let track = MediaTrack(id: 1, name: "Track", codec: "vorbis")
        XCTAssertEqual(track.formattedCodec, "Vorbis")
    }

    // Subtitle codecs
    func testFormattedCodecMapsSRT() {
        let track = MediaTrack(id: 1, name: "Track", codec: "subrip")
        XCTAssertEqual(track.formattedCodec, "SRT")

        let trackAlt = MediaTrack(id: 1, name: "Track", codec: "srt")
        XCTAssertEqual(trackAlt.formattedCodec, "SRT")
    }

    func testFormattedCodecMapsASS() {
        let track = MediaTrack(id: 1, name: "Track", codec: "ass")
        XCTAssertEqual(track.formattedCodec, "ASS")

        let trackSSA = MediaTrack(id: 1, name: "Track", codec: "ssa")
        XCTAssertEqual(trackSSA.formattedCodec, "ASS")
    }

    func testFormattedCodecMapsPGS() {
        let track = MediaTrack(id: 1, name: "Track", codec: "pgs")
        XCTAssertEqual(track.formattedCodec, "PGS")

        let trackHDMV = MediaTrack(id: 1, name: "Track", codec: "hdmv_pgs_subtitle")
        XCTAssertEqual(trackHDMV.formattedCodec, "PGS")

        let trackPGSSub = MediaTrack(id: 1, name: "Track", codec: "pgssub")
        XCTAssertEqual(trackPGSSub.formattedCodec, "PGS")
    }

    func testFormattedCodecMapsVOBSUB() {
        let track = MediaTrack(id: 1, name: "Track", codec: "dvdsub")
        XCTAssertEqual(track.formattedCodec, "VOBSUB")

        let trackAlt = MediaTrack(id: 1, name: "Track", codec: "dvd_subtitle")
        XCTAssertEqual(trackAlt.formattedCodec, "VOBSUB")
    }

    func testFormattedCodecMapsWebVTT() {
        let track = MediaTrack(id: 1, name: "Track", codec: "webvtt")
        XCTAssertEqual(track.formattedCodec, "WebVTT")

        let trackAlt = MediaTrack(id: 1, name: "Track", codec: "vtt")
        XCTAssertEqual(trackAlt.formattedCodec, "WebVTT")
    }

    func testFormattedCodecMapsTX3G() {
        let track = MediaTrack(id: 1, name: "Track", codec: "mov_text")
        XCTAssertEqual(track.formattedCodec, "TX3G")
    }

    func testFormattedCodecMapsCC() {
        let track = MediaTrack(id: 1, name: "Track", codec: "cc_dec")
        XCTAssertEqual(track.formattedCodec, "CC")
    }

    func testFormattedCodecHandlesUnknownCodec() {
        let track = MediaTrack(id: 1, name: "Track", codec: "unknown_codec")
        XCTAssertEqual(track.formattedCodec, "UNKNOWN_CODEC")
    }

    func testFormattedCodecHandlesNilCodec() {
        let track = MediaTrack(id: 1, name: "Track", codec: nil)
        XCTAssertEqual(track.formattedCodec, "Audio")
    }

    // MARK: - Channel Inference Tests

    func testInfersChannelsFromExplicitProperty() {
        let track = MediaTrack(id: 1, name: "English", channels: 6)
        XCTAssertEqual(track.channelLayout, "5.1")
    }

    func testInfersChannelsFromNameChNotation() {
        let track = MediaTrack(id: 1, name: "English 6ch", channels: nil)
        XCTAssertEqual(track.channelLayout, "5.1")

        let track2ch = MediaTrack(id: 1, name: "English 2ch", channels: nil)
        XCTAssertEqual(track2ch.channelLayout, "Stereo")

        let track8ch = MediaTrack(id: 1, name: "English 8ch", channels: nil)
        XCTAssertEqual(track8ch.channelLayout, "7.1")
    }

    func testInfersChannelsFrom7Point1() {
        let track = MediaTrack(id: 1, name: "English 7.1 TrueHD", channels: nil)
        XCTAssertEqual(track.channelLayout, "7.1")
    }

    func testInfersChannelsFrom5Point1() {
        let track = MediaTrack(id: 1, name: "English 5.1 AC3", channels: nil)
        XCTAssertEqual(track.channelLayout, "5.1")
    }

    func testInfersChannelsFromStereo() {
        let track = MediaTrack(id: 1, name: "English Stereo", channels: nil)
        XCTAssertEqual(track.channelLayout, "Stereo")
    }

    func testInfersChannelsFromMono() {
        let track = MediaTrack(id: 1, name: "English Mono", channels: nil)
        XCTAssertEqual(track.channelLayout, "Mono")
    }

    func testChannelLayoutReturnsEmptyForUnknown() {
        let track = MediaTrack(id: 1, name: "English", channels: nil)
        XCTAssertEqual(track.channelLayout, "")
    }

    func testExplicitChannelsTakePrecedence() {
        // Even if name suggests stereo, explicit channels property wins
        let track = MediaTrack(id: 1, name: "Stereo Track", channels: 6)
        XCTAssertEqual(track.channelLayout, "5.1")
    }

    // MARK: - Channel Layout Display Tests

    func testChannelLayoutDisplaysMono() {
        let track = MediaTrack(id: 1, name: "Track", channels: 1)
        XCTAssertEqual(track.channelLayout, "Mono")
    }

    func testChannelLayoutDisplaysStereo() {
        let track = MediaTrack(id: 1, name: "Track", channels: 2)
        XCTAssertEqual(track.channelLayout, "Stereo")
    }

    func testChannelLayoutDisplays2Point1() {
        let track = MediaTrack(id: 1, name: "Track", channels: 3)
        XCTAssertEqual(track.channelLayout, "2.1")
    }

    func testChannelLayoutDisplays5Point1() {
        let track = MediaTrack(id: 1, name: "Track", channels: 6)
        XCTAssertEqual(track.channelLayout, "5.1")
    }

    func testChannelLayoutDisplays7Point1() {
        let track = MediaTrack(id: 1, name: "Track", channels: 8)
        XCTAssertEqual(track.channelLayout, "7.1")
    }

    func testChannelLayoutDisplaysGenericForOtherCounts() {
        let track = MediaTrack(id: 1, name: "Track", channels: 4)
        XCTAssertEqual(track.channelLayout, "4ch")

        let track5 = MediaTrack(id: 1, name: "Track", channels: 5)
        XCTAssertEqual(track5.channelLayout, "5ch")
    }

    // MARK: - Language Display Tests

    func testLanguageDisplayConvertsCode() {
        let track = MediaTrack(id: 1, name: "Track", languageCode: "eng")
        XCTAssertEqual(track.languageDisplay, "ENGLISH")
    }

    func testLanguageDisplayConvertsISO639_1() {
        let track = MediaTrack(id: 1, name: "Track", languageCode: "en")
        XCTAssertEqual(track.languageDisplay, "ENGLISH")
    }

    func testLanguageDisplayConvertsSpanish() {
        let track = MediaTrack(id: 1, name: "Track", languageCode: "spa")
        XCTAssertEqual(track.languageDisplay, "SPANISH")

        let trackEs = MediaTrack(id: 1, name: "Track", languageCode: "es")
        XCTAssertEqual(trackEs.languageDisplay, "SPANISH")
    }

    func testLanguageDisplayConvertsFrench() {
        let track = MediaTrack(id: 1, name: "Track", languageCode: "fra")
        XCTAssertEqual(track.languageDisplay, "FRENCH")

        let trackFr = MediaTrack(id: 1, name: "Track", languageCode: "fr")
        XCTAssertEqual(trackFr.languageDisplay, "FRENCH")
    }

    func testLanguageDisplayConvertsGerman() {
        let track = MediaTrack(id: 1, name: "Track", languageCode: "deu")
        XCTAssertEqual(track.languageDisplay, "GERMAN")

        let trackDe = MediaTrack(id: 1, name: "Track", languageCode: "de")
        XCTAssertEqual(trackDe.languageDisplay, "GERMAN")

        let trackGer = MediaTrack(id: 1, name: "Track", languageCode: "ger")
        XCTAssertEqual(trackGer.languageDisplay, "GERMAN")
    }

    func testLanguageDisplayConvertsJapanese() {
        let track = MediaTrack(id: 1, name: "Track", languageCode: "jpn")
        XCTAssertEqual(track.languageDisplay, "JAPANESE")

        let trackJa = MediaTrack(id: 1, name: "Track", languageCode: "ja")
        XCTAssertEqual(trackJa.languageDisplay, "JAPANESE")
    }

    func testLanguageDisplayConvertsKorean() {
        let track = MediaTrack(id: 1, name: "Track", languageCode: "kor")
        XCTAssertEqual(track.languageDisplay, "KOREAN")

        let trackKo = MediaTrack(id: 1, name: "Track", languageCode: "ko")
        XCTAssertEqual(trackKo.languageDisplay, "KOREAN")
    }

    func testLanguageDisplayConvertsChinese() {
        let track = MediaTrack(id: 1, name: "Track", languageCode: "zho")
        XCTAssertEqual(track.languageDisplay, "CHINESE")

        let trackZh = MediaTrack(id: 1, name: "Track", languageCode: "zh")
        XCTAssertEqual(trackZh.languageDisplay, "CHINESE")

        let trackChi = MediaTrack(id: 1, name: "Track", languageCode: "chi")
        XCTAssertEqual(trackChi.languageDisplay, "CHINESE")
    }

    func testLanguageDisplayConvertsRussian() {
        let track = MediaTrack(id: 1, name: "Track", languageCode: "rus")
        XCTAssertEqual(track.languageDisplay, "RUSSIAN")

        let trackRu = MediaTrack(id: 1, name: "Track", languageCode: "ru")
        XCTAssertEqual(trackRu.languageDisplay, "RUSSIAN")
    }

    func testLanguageDisplayHandlesUnknown() {
        let track = MediaTrack(id: 1, name: "Track", languageCode: "und")
        // "und" (undetermined) may map to various values via Locale, e.g., "UNKNOWN LANGUAGE"
        let result = track.languageDisplay
        // Accept any reasonable representation of "unknown/undetermined"
        let acceptableValues = ["UNKNOWN", "UNDETERMINED", "UNKNOWN LANGUAGE"]
        XCTAssertTrue(acceptableValues.contains(result), "Expected one of \(acceptableValues), got \(result)")
    }

    func testLanguageDisplayHandlesNil() {
        let track = MediaTrack(id: 1, name: "Track", languageCode: nil)
        XCTAssertEqual(track.languageDisplay, "UNKNOWN")
    }

    func testLanguageDisplayFallsBackToLanguageProperty() {
        let track = MediaTrack(id: 1, name: "Track", language: "eng", languageCode: nil)
        XCTAssertEqual(track.languageDisplay, "ENGLISH")
    }

    func testLanguageDisplayUppercasesUnknownCodes() {
        let track = MediaTrack(id: 1, name: "Track", languageCode: "xyz")
        XCTAssertEqual(track.languageDisplay, "XYZ")
    }

    // MARK: - Audio Format String Tests

    func testAudioFormatStringCombinesCodecAndChannels() {
        let track = MediaTrack(id: 1, name: "Track", codec: "truehd", channels: 8)
        XCTAssertEqual(track.audioFormatString, "TrueHD · 7.1")
    }

    func testAudioFormatStringWithOnlyCodec() {
        let track = MediaTrack(id: 1, name: "Track", codec: "aac", channels: nil)
        XCTAssertEqual(track.audioFormatString, "AAC")
    }

    // MARK: - Display Name Tests

    func testDisplayNameIncludesForced() {
        let track = MediaTrack(id: 1, name: "English", isForced: true)
        XCTAssertEqual(track.displayName, "English (Forced)")
    }

    func testDisplayNameIncludesSDH() {
        let track = MediaTrack(id: 1, name: "English", isHearingImpaired: true)
        XCTAssertEqual(track.displayName, "English (SDH)")
    }

    func testDisplayNameIncludesBothForcedAndSDH() {
        let track = MediaTrack(id: 1, name: "English", isForced: true, isHearingImpaired: true)
        XCTAssertEqual(track.displayName, "English (Forced) (SDH)")
    }

    func testDisplayNameWithoutFlags() {
        let track = MediaTrack(id: 1, name: "English")
        XCTAssertEqual(track.displayName, "English")
    }
}
