import XCTest
@testable import Rivulet

/// Issue #201 — regression guard.
///
/// A title with several subtitle tracks in the SAME language could only ever
/// select the first of them. The picker listed Plex streams while the engine
/// selects by container stream index, and the translation between the two lists
/// matched on language + codec — not a unique key. Three English SRT tracks all
/// resolved to the same engine index, so only the first was selectable. Since
/// the first is typically the forced/foreign-parts track, users could not turn
/// on real English subtitles at all.
///
/// The fix removed the translation entirely: `TrackMerge` builds ONE list whose
/// ids ARE engine indices. These tests assert the property that matters to the
/// user — every same-language track is independently addressable — at the level
/// of the list the picker actually renders.
final class SameLanguageTrackSelectionTests: XCTestCase {

    /// Engine track: `id` IS the container stream index.
    private func engineSub(id: Int, lang: String = "eng", codec: String = "subrip") -> MediaTrack {
        MediaTrack(id: id, name: lang, language: lang, languageCode: lang, codec: codec,
                   extendedDisplayTitle: nil, streamIndex: id)
    }

    /// Plex stream: `streamIndex` is `PlexStream.index`, the same container index.
    private func plexSub(id: Int, streamIndex: Int, name: String, lang: String = "eng",
                         codec: String = "srt", forced: Bool = false, hi: Bool = false) -> MediaTrack {
        MediaTrack(id: id, name: name, language: lang, languageCode: lang, codec: codec,
                   isForced: forced, isHearingImpaired: hi, streamIndex: streamIndex)
    }

    /// The reported case: 3 English subtitle tracks, first one forced.
    /// Every one must be individually selectable.
    func testEverySameLanguageSubtitleIsIndependentlySelectable() {
        let merged = TrackMerge.mergeSubtitles(
            engine: [engineSub(id: 2), engineSub(id: 3), engineSub(id: 4)],
            plex: [
                plexSub(id: 500, streamIndex: 2, name: "English (Forced)", forced: true),
                plexSub(id: 501, streamIndex: 3, name: "English"),
                plexSub(id: 502, streamIndex: 4, name: "English (SDH)", hi: true)
            ]
        )

        // The three rows the picker renders have three DISTINCT ids...
        let ids = merged.map(\.id)
        XCTAssertEqual(Set(ids).count, 3, "same-language tracks must not collapse onto one id")

        // ...and each id is the engine index the engine will actually honor,
        // so selecting row N plays track N. This is the whole bug.
        XCTAssertEqual(ids, [2, 3, 4])
    }

    /// The user's real goal in #201: reach the non-forced English track. Before
    /// the fix this was unreachable — it mapped to the forced track's index.
    func testCanSelectTheNonForcedEnglishTrack() {
        let merged = TrackMerge.mergeSubtitles(
            engine: [engineSub(id: 2), engineSub(id: 3)],
            plex: [
                plexSub(id: 500, streamIndex: 2, name: "English (Forced)", forced: true),
                plexSub(id: 501, streamIndex: 3, name: "English")
            ]
        )

        let regularEnglish = merged.first { $0.languageCode == "eng" && !$0.isForced }
        XCTAssertNotNil(regularEnglish)
        XCTAssertEqual(regularEnglish?.id, 3, "must map to its OWN engine track, not the forced one's")
        XCTAssertNotEqual(regularEnglish?.id, merged.first(where: \.isForced)?.id)
    }

    /// The reporter confirmed mov_text reproduces as well — nothing codec-specific.
    func testSameLanguageMovTextTracksAreIndependentlySelectable() {
        let merged = TrackMerge.mergeSubtitles(
            engine: [engineSub(id: 3, codec: "mov_text"), engineSub(id: 4, codec: "mov_text")],
            plex: [plexSub(id: 500, streamIndex: 3, name: "English", codec: "mov_text"),
                   plexSub(id: 501, streamIndex: 4, name: "English", codec: "mov_text")]
        )
        XCTAssertEqual(merged.map(\.id), [3, 4])
    }

    /// Round-trip: what the engine reports as active reflects back onto the row
    /// the user picked, so the checkmark lands on the right row.
    func testActiveEngineTrackIdentifiesTheCorrectRow() {
        let merged = TrackMerge.mergeSubtitles(
            engine: [engineSub(id: 2), engineSub(id: 3), engineSub(id: 4)],
            plex: [plexSub(id: 500, streamIndex: 2, name: "English (Forced)", forced: true),
                   plexSub(id: 501, streamIndex: 3, name: "English"),
                   plexSub(id: 502, streamIndex: 4, name: "English (SDH)", hi: true)]
        )

        // Engine says "track 4 is active" -> that IS the row's id, no mapping.
        let active = merged.first { $0.id == 4 }
        XCTAssertEqual(active?.name, "English (SDH)")
    }

    /// Same-language AUDIO (a main mix and a commentary sharing codec and
    /// channel count) had the identical collapse.
    func testSameLanguageAudioTracksAreIndependentlySelectable() {
        let engineAudio = { (id: Int) in
            MediaTrack(id: id, name: "English", language: "eng", languageCode: "eng",
                       codec: "eac3", channels: 6, streamIndex: id)
        }
        let merged = TrackMerge.mergeAudio(
            engine: [engineAudio(1), engineAudio(2)],
            plex: [
                MediaTrack(id: 50, name: "English", languageCode: "eng", codec: "eac3",
                           extendedDisplayTitle: "English (EAC3 5.1)", channels: 6, streamIndex: 1),
                MediaTrack(id: 51, name: "English", languageCode: "eng", codec: "eac3",
                           extendedDisplayTitle: "English (EAC3 5.1) - Director's Commentary",
                           channels: 6, streamIndex: 2)
            ]
        )
        XCTAssertEqual(Set(merged.map(\.id)).count, 2)
        XCTAssertEqual(merged.map(\.id), [1, 2])
    }
}
