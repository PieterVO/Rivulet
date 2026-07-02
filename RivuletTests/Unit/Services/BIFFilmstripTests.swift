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
}
