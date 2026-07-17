// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SubtitleModelActiveCuesTests.swift
//  RivuletTests
//
//  Pure-logic tests for SubtitleModel.activeCues — window lookup, the
//  delaySeconds offset, and the content-identity dedupe that defends against
//  AetherEngine 5.0.1's rewind cue duplication.
//

import XCTest
import CoreGraphics
@testable import Rivulet

@MainActor
final class SubtitleModelActiveCuesTests: XCTestCase {

    // MARK: - Builders

    private func textCue(
        id: Int,
        start: Double,
        end: Double,
        _ text: String
    ) -> AetherSubtitleCue {
        AetherSubtitleCue(id: id, startTime: start, endTime: end, body: .text(text))
    }

    private func imageCue(
        id: Int,
        start: Double,
        end: Double,
        image: CGImage,
        position: CGRect = CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.1)
    ) -> AetherSubtitleCue {
        AetherSubtitleCue(
            id: id,
            startTime: start,
            endTime: end,
            body: .image(cgImage: image, position: position)
        )
    }

    /// A 1x1 opaque bitmap. Each call returns a distinct CGImage object.
    private func makeImage() throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func bodies(_ cues: [AetherSubtitleCue]) -> [String] {
        cues.compactMap { cue in
            if case .text(let s) = cue.body { return s }
            return nil
        }
    }

    // MARK: - Dedupe: re-decode duplicates collapse

    /// AetherEngine's `.resetAndDecode` drain re-appends the backscan window on
    /// every rewind without clearing `subtitleCues`, so one line accumulates a
    /// copy per rewind across it. All copies are byte-identical:
    /// same start, same end, same text. They must collapse to exactly one.
    func test_identicalCueInsertedFiveTimes_yieldsOne() {
        let model = SubtitleModel()

        // Same (start, end, text) five times. Ids differ because the engine's
        // per-decoder counter restarts at 0 on each decoder reset — which is
        // precisely why id is not a usable identity.
        let dupes = (0..<5).map { i in
            textCue(id: i, start: 10, end: 14, "Where are you going?")
        }
        model.update(cues: dupes)
        model.sourceTime = 12

        let active = model.activeCues
        XCTAssertEqual(active.count, 1, "five identical re-decoded copies must collapse to one")
        XCTAssertEqual(bodies(active), ["Where are you going?"])
    }

    /// The duplicates in the wild are interleaved with other lines, not adjacent.
    func test_duplicatesInterleavedWithOtherCues_collapse() {
        let model = SubtitleModel()
        model.update(cues: [
            textCue(id: 0, start: 10, end: 14, "Line A"),
            textCue(id: 1, start: 11, end: 13, "Line B"),
            textCue(id: 0, start: 10, end: 14, "Line A"),   // re-decoded copy
            textCue(id: 1, start: 11, end: 13, "Line B"),   // re-decoded copy
            textCue(id: 2, start: 12, end: 16, "Line C")
        ])
        model.sourceTime = 12.5

        let active = model.activeCues
        XCTAssertEqual(active.count, 3)
        XCTAssertEqual(bodies(active), ["Line A", "Line B", "Line C"],
                       "dedupe must preserve startTime ordering")
    }

    // MARK: - Dedupe: REGRESSION GUARD (simultaneous speakers)

    /// THE REGRESSION GUARD. Two genuine simultaneous speakers share a
    /// startTime (and here an endTime too) but carry DIFFERENT text. Both must
    /// survive. This test fails the moment someone "simplifies" the dedupe key
    /// down to startTime — which would silently swallow a real speaker's line.
    func test_sameStartSameEnd_differentText_bothSurvive() {
        let model = SubtitleModel()
        model.update(cues: [
            textCue(id: 0, start: 10, end: 14, "- Get down!"),
            textCue(id: 1, start: 10, end: 14, "- I'm trying!")
        ])
        model.sourceTime = 11

        let active = model.activeCues
        XCTAssertEqual(active.count, 2,
                       "simultaneous speakers differ in text and must BOTH render")
        XCTAssertEqual(bodies(active), ["- Get down!", "- I'm trying!"])
    }

    /// Same start, different end, same text is NOT provably a re-decode
    /// duplicate (the engine could have re-timed the cue), so both survive:
    /// the key is full content identity, not (start, text).
    func test_sameStartSameText_differentEnd_bothSurvive() {
        let model = SubtitleModel()
        model.update(cues: [
            textCue(id: 0, start: 10, end: 13, "Hello"),
            textCue(id: 1, start: 10, end: 15, "Hello")
        ])
        model.sourceTime = 11

        XCTAssertEqual(model.activeCues.count, 2)
    }

    // MARK: - Dedupe: bitmap cues

    /// Bitmap duplicates keyed on CGImage reference identity + position: the
    /// same image object re-inserted collapses.
    func test_identicalBitmapCue_collapses() throws {
        let image = try makeImage()
        let model = SubtitleModel()
        model.update(cues: [
            imageCue(id: 0, start: 10, end: 14, image: image),
            imageCue(id: 0, start: 10, end: 14, image: image)
        ])
        model.sourceTime = 12

        XCTAssertEqual(model.activeCues.count, 1)
    }

    /// Conservative: two image cues with the same start/end/position but
    /// DIFFERENT CGImage refs cannot be proven duplicates, so both are kept.
    /// (PGS legitimately emits multiple simultaneous bitmaps.)
    func test_differentBitmapRefs_sameGeometry_bothSurvive() throws {
        let a = try makeImage()
        let b = try makeImage()
        XCTAssertFalse(a === b, "test builder must produce distinct CGImage objects")

        let model = SubtitleModel()
        model.update(cues: [
            imageCue(id: 0, start: 10, end: 14, image: a),
            imageCue(id: 1, start: 10, end: 14, image: b)
        ])
        model.sourceTime = 12

        XCTAssertEqual(model.activeCues.count, 2,
                       "never drop a cue we cannot prove is a duplicate")
    }

    // MARK: - Window behavior

    func test_cueOutsideWindow_isExcluded() {
        let model = SubtitleModel()
        model.update(cues: [
            textCue(id: 0, start: 10, end: 12, "Early"),
            textCue(id: 1, start: 20, end: 22, "Late")
        ])

        // Before the first cue starts.
        model.sourceTime = 5
        XCTAssertEqual(model.activeCues.count, 0)

        // After the first cue ends, before the second starts.
        model.sourceTime = 15
        XCTAssertEqual(model.activeCues.count, 0, "gap between cues shows nothing")

        // Inside the second cue.
        model.sourceTime = 21
        XCTAssertEqual(bodies(model.activeCues), ["Late"])

        // After every cue has ended.
        model.sourceTime = 30
        XCTAssertEqual(model.activeCues.count, 0)
    }

    func test_cueBoundaries_areInclusive() {
        let model = SubtitleModel()
        model.update(cues: [textCue(id: 0, start: 10, end: 12, "Edge")])

        model.sourceTime = 10
        XCTAssertEqual(bodies(model.activeCues), ["Edge"], "startTime is inclusive")

        model.sourceTime = 12
        XCTAssertEqual(bodies(model.activeCues), ["Edge"], "endTime is inclusive")

        model.sourceTime = 12.001
        XCTAssertEqual(model.activeCues.count, 0)
    }

    // MARK: - delaySeconds

    /// Effective time = sourceTime - delaySeconds. A positive delay shifts the
    /// window earlier in the cue timeline; a negative delay shifts it later.
    func test_delaySeconds_shiftsWhichCuesAreActive() {
        let model = SubtitleModel()
        model.update(cues: [
            textCue(id: 0, start: 10, end: 12, "First"),
            textCue(id: 1, start: 20, end: 22, "Second")
        ])

        model.sourceTime = 21
        model.delaySeconds = 0
        XCTAssertEqual(bodies(model.activeCues), ["Second"])

        // +10 delay: effective t = 11, so "First" is what's on screen.
        model.delaySeconds = 10
        XCTAssertEqual(bodies(model.activeCues), ["First"],
                       "positive delaySeconds pulls earlier cues into view")

        // -10 delay at sourceTime 11: effective t = 21 -> "Second".
        model.sourceTime = 11
        model.delaySeconds = -10
        XCTAssertEqual(bodies(model.activeCues), ["Second"],
                       "negative delaySeconds pushes later cues into view")

        // A delay that lands in the gap shows nothing.
        model.sourceTime = 21
        model.delaySeconds = 6      // effective t = 15
        XCTAssertEqual(model.activeCues.count, 0)
    }

    /// The dedupe must survive the delay offset — it operates on the same
    /// window walk, so a delayed lookup still collapses duplicates.
    func test_delaySeconds_stillDedupes() {
        let model = SubtitleModel()
        model.update(cues: (0..<3).map { textCue(id: $0, start: 10, end: 14, "Dupe") })

        model.sourceTime = 22
        model.delaySeconds = 10     // effective t = 12
        XCTAssertEqual(bodies(model.activeCues), ["Dupe"])
    }

    // MARK: - Empty / degenerate

    func test_emptyCueList_returnsEmpty() {
        let model = SubtitleModel()
        model.sourceTime = 10
        XCTAssertEqual(model.activeCues.count, 0)
    }

    /// maxCueDuration is the backward-walk window; a long cue must still be
    /// found when the playhead sits deep inside it.
    func test_longCue_stillFoundLateInItsSpan() {
        let model = SubtitleModel()
        model.update(cues: [
            textCue(id: 0, start: 0, end: 30, "A very long cue"),
            textCue(id: 1, start: 29, end: 31, "Short")
        ])
        model.sourceTime = 29.5

        XCTAssertEqual(bodies(model.activeCues), ["A very long cue", "Short"],
                       "maxCueDuration must widen to cover the 30s cue")
    }
}
