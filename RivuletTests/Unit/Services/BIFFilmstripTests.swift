import XCTest
@testable import Rivulet

final class BIFFilmstripTests: XCTestCase {

    /// Synthesizes a valid BIF container: `frames` payloads at 1-per-
    /// interval timestamps (timestamp field = frame number, real time =
    /// timestamp * intervalMs, matching Plex output).
    private func makeBIF(frameCount: Int, intervalMs: UInt32) -> Data {
        var data = Data([0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]) // magic
        func appendLE(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        appendLE(0)                    // version
        appendLE(UInt32(frameCount))   // count
        appendLE(intervalMs)           // interval
        data.append(Data(repeating: 0, count: 44)) // reserved to byte 64
        let payloads: [Data] = (0..<frameCount).map { Data([UInt8($0 + 1), 0xFF]) }
        var offset = UInt32(64 + (frameCount + 1) * 8)
        for (i, p) in payloads.enumerated() {
            appendLE(UInt32(i))        // timestamp = frame number
            appendLE(offset)
            offset += UInt32(p.count)
        }
        appendLE(UInt32.max)           // end-marker timestamp (unused)
        appendLE(offset)               // end offset
        payloads.forEach { data.append($0) }
        return data
    }

    func testParseSyntheticBIF() {
        let bif = BIFData(data: makeBIF(frameCount: 5, intervalMs: 10_000))
        XCTAssertEqual(bif?.frameCount, 5)
        XCTAssertEqual(bif?.intervalMs, 10_000)
        XCTAssertEqual(bif?.frames[2].imageData.first, 3)
    }

    func testFrameIndexNearest() {
        let bif = BIFData(data: makeBIF(frameCount: 5, intervalMs: 10_000))!
        XCTAssertEqual(bif.frameIndex(at: 0), 0)      // 0s → frame 0
        XCTAssertEqual(bif.frameIndex(at: 14), 1)     // 14s → frame 1 (10s)
        XCTAssertEqual(bif.frameIndex(at: 16), 2)     // 16s → frame 2 (20s)
        XCTAssertEqual(bif.frameIndex(at: 9_999), 4)  // clamps to last
    }

    func testFrameIndexEmpty() {
        let bif = BIFData(data: makeBIF(frameCount: 0, intervalMs: 10_000))
        XCTAssertNil(bif?.frameIndex(at: 5))
    }

    /// Same as `makeBIF`, but corrupts one middle frame's index entry so
    /// its offset points beyond the end of the file. The parser's
    /// offset-bounds guard (`start < data.count`) silently drops that
    /// entry via `continue`, desyncing `frames[i]` from timestamp
    /// multiplier `i` for every frame after the drop.
    private func makeBIFWithDroppedMiddleFrame(frameCount: Int, intervalMs: UInt32, dropIndex: Int) -> Data {
        var data = Data([0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]) // magic
        func appendLE(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        appendLE(0)                    // version
        appendLE(UInt32(frameCount))   // count
        appendLE(intervalMs)           // interval
        data.append(Data(repeating: 0, count: 44)) // reserved to byte 64
        let payloads: [Data] = (0..<frameCount).map { Data([UInt8($0 + 1), 0xFF]) }
        var offset = UInt32(64 + (frameCount + 1) * 8)
        var offsets: [UInt32] = []
        for p in payloads {
            offsets.append(offset)
            offset += UInt32(p.count)
        }
        let endOffset = offset
        for i in 0..<frameCount {
            appendLE(UInt32(i)) // timestamp = frame number
            if i == dropIndex {
                // Malformed: offset points past the end of the file, so
                // `start < data.count` fails and the parser drops it.
                appendLE(endOffset + 1_000_000)
            } else {
                appendLE(offsets[i])
            }
        }
        appendLE(UInt32.max)  // end-marker timestamp (unused)
        appendLE(endOffset)   // end offset
        payloads.forEach { data.append($0) }
        return data
    }

    /// Regression test for the reviewer finding in
    /// .superpowers/sdd/task-3-review.md: `frameIndex(at:)` must stay
    /// timestamp-correct even when the parser drops a malformed frame
    /// mid-array, not just assume `frames[i].timestamp == i`.
    func testFrameIndexNearestSurvivesDroppedMiddleFrame() {
        // 6 frames at 10s spacing. Corrupting entry 3's offset breaks its
        // own span AND entry 2's span (whose `end` is entry 3's `start`,
        // per the parser's `nextOffset` logic), so the parser drops BOTH
        // index 2 (timestamp 2 → 20s) and index 3 (timestamp 3 → 30s).
        // Surviving frames: [ts0, ts1, ts4, ts5] (4 entries, array
        // position no longer equals timestamp past index 1).
        let data = makeBIFWithDroppedMiddleFrame(frameCount: 6, intervalMs: 10_000, dropIndex: 3)
        let bif = BIFData(data: data)!
        XCTAssertEqual(bif.frameCount, 4, "the malformed entry and its collateral neighbor should have been dropped by the parser")
        XCTAssertFalse(bif.timestampsAreContiguous, "a drop must be recorded so frameIndex(at:) stops trusting raw array position")

        // A lookup for a time AFTER the drop point (e.g. 41s, nearest to
        // timestamp 4 → 40s) must still resolve to the frame whose real
        // time (timestamp * intervalMs) is nearest -- i.e. the frame
        // carrying timestamp 4, found by its stored .timestamp, not by
        // naively indexing frames[Int((41/10).rounded())] == frames[4]
        // (out of bounds / wrong frame once the array is desynced from
        // the raw index).
        guard let idx = bif.frameIndex(at: 41) else {
            return XCTFail("expected a frame index")
        }
        XCTAssertEqual(bif.frames[idx].timestamp, 4,
                        "lookup at 41s should resolve to the frame with real timestamp 4 (40s), not be thrown off by the dropped frames' array-position gap")

        // A lookup landing in the gap (24s) should resolve to whichever
        // surviving frame is nearest by real time: ts1=10s (14s away) is
        // closer than ts4=40s (16s away).
        guard let idxNearGap = bif.frameIndex(at: 24) else {
            return XCTFail("expected a frame index")
        }
        XCTAssertEqual(bif.frames[idxNearGap].timestamp, 1,
                        "lookup at 24s should resolve to the nearest surviving frame by real time (timestamp 1 / 10s), not an array-position guess")
    }

    /// Regression test for the walk-through finding: a BIF whose real-time
    /// coverage is shorter than the media's full duration (generation
    /// truncated, or produced against a stale duration) used to produce
    /// several identical tail tiles — every requested time past the BIF's
    /// last frame clamped to the same `frames.count - 1` index in
    /// `frameIndex(at:)`. `frameIndices(forTimes:bif:)` must spread those
    /// overshooting requests across the BIF's own covered range instead.
    func testFrameIndicesSpreadsOvershotTailAcrossAvailableFrames() {
        // 60 frames at 10s spacing = 590s of real coverage (frame N's real
        // time is N * 10s, so the last frame, index 59, covers 590s).
        let bif = BIFData(data: makeBIF(frameCount: 60, intervalMs: 10_000))!

        // Simulate a 23-minute (1380s) episode's evenly spaced samples
        // (`duration * (i + 0.5) / count` construction) reaching well
        // beyond the BIF's 590s of real coverage. Hand-verified split:
        // samples 0...4 (up to
        // 517.5s) are in-range; samples 5...11 (7 samples, 632.5s onward)
        // overshoot. The last in-range sample (517.5s) resolves to frame
        // index 52, leaving indices 53...59 (exactly 7) unused — enough to
        // give every overshot sample its own distinct frame.
        let count = 12
        let duration: TimeInterval = 1380
        let times = (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }

        let indices = PlexThumbnailService.frameIndices(forTimes: times, bif: bif)
        XCTAssertEqual(indices.count, times.count, "must stay 1:1 with the input so tile positions on the ribbon don't shift")

        let inRangeCount = 5
        XCTAssertEqual(Array(indices.prefix(inRangeCount)), [6, 17, 29, 40, 52].map { Optional($0) },
                       "in-coverage samples resolve normally, unaffected by the tail remap")

        // Without the fix, every one of these would resolve to the same
        // clamped final index (59). With it, the tail spreads across the
        // frames left unused by the in-range samples: 53...59.
        let tailIndices = indices.dropFirst(inRangeCount).compactMap { $0 }
        XCTAssertEqual(tailIndices, [53, 54, 55, 56, 57, 58, 59],
                       "each overshot tail sample should land on a distinct, increasing BIF frame ending at the true final frame")
    }

    /// When the tail overshoots by more samples than there are unused
    /// frames left to spread across, several tail positions must still
    /// collapse onto the same frame — there is no more real data to show —
    /// but the fix must not regress into resolving to something other than
    /// the true final frame, and must never crash on the degenerate ranges.
    func testFrameIndicesTailWithNoHeadroomStillEndsOnFinalFrame() {
        // 10 frames = 90s of coverage. The 9th (last-in-range) sample sits
        // right at frame 9 already, leaving zero frames of headroom for the
        // tail — every tail position must fall back to the final frame.
        let bif = BIFData(data: makeBIF(frameCount: 10, intervalMs: 10_000))!
        let count = 12
        let duration: TimeInterval = 1380
        let times = (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }

        let indices = PlexThumbnailService.frameIndices(forTimes: times, bif: bif)
        XCTAssertEqual(indices.count, times.count)
        XCTAssertEqual(indices.last, 9, "the final sample must still resolve to the BIF's true last frame")
        XCTAssertTrue(indices.compactMap { $0 }.allSatisfy { $0 <= 9 }, "no index may exceed the BIF's actual frame range")
    }

    func testFrameIndicesPassesThroughWhenFullyInRange() {
        // BIF covers the whole 50s span requested — nothing to remap.
        let bif = BIFData(data: makeBIF(frameCount: 6, intervalMs: 10_000))! // covers [0, 50s]
        let times: [TimeInterval] = [5, 15, 25, 35, 45]
        let indices = PlexThumbnailService.frameIndices(forTimes: times, bif: bif)
        XCTAssertEqual(indices, times.map { bif.frameIndex(at: $0) },
                       "fully in-range requests resolve exactly as plain frameIndex(at:) would")
    }
}
