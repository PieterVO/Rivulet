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
}
