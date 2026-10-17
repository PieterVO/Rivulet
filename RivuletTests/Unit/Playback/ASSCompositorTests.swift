import CoreGraphics
import XCTest
@testable import Rivulet

final class ASSCompositorTests: XCTestCase {

    private var allocations: [UnsafeMutablePointer<UInt8>] = []

    override func tearDown() {
        allocations.forEach { $0.deallocate() }
        allocations.removeAll()
        super.tearDown()
    }

    private func bitmap(_ mask: [UInt8], width: Int, height: Int, stride: Int? = nil,
                        color: UInt32, x: Int, y: Int) -> ASSCompositor.Bitmap {
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: mask.count)
        pointer.initialize(from: mask, count: mask.count)
        allocations.append(pointer)
        return ASSCompositor.Bitmap(width: width, height: height, stride: stride ?? width,
                                    pixels: pointer, color: color, x: x, y: y)
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        Array((image.dataProvider?.data as Data?) ?? Data())
    }

    private func single(_ bitmaps: [ASSCompositor.Bitmap]) throws -> (image: CGImage, rect: CGRect) {
        let regions = ASSCompositor.composite(bitmaps)
        XCTAssertEqual(regions.count, 1)
        return try XCTUnwrap(regions.first)
    }

    func test_opaqueWhite_isPlacedAtItsOrigin() throws {
        let result = try single([bitmap([255, 255], width: 2, height: 1, color: 0xFFFFFF00, x: 3, y: 4)])
        XCTAssertEqual(result.rect, CGRect(x: 3, y: 4, width: 2, height: 1))
        XCTAssertEqual(bytes(result.image), [255, 255, 255, 255, 255, 255, 255, 255])
    }

    func test_fullyTransparentColour_drawsNothing() {
        XCTAssertTrue(ASSCompositor.composite([
            bitmap([255], width: 1, height: 1, color: 0xFFFFFFFF, x: 0, y: 0)
        ]).isEmpty)
    }

    func test_halfBlueOverRed_blendsSourceOverPremultiplied() throws {
        let result = try single([
            bitmap([255], width: 1, height: 1, color: 0xFF000000, x: 0, y: 0),
            bitmap([255], width: 1, height: 1, color: 0x0000FF7F, x: 0, y: 0)
        ])
        // Memory order B, G, R, A. Blue at opacity 128 over opaque red.
        XCTAssertEqual(bytes(result.image), [128, 0, 127, 255])
    }

    func test_halfBlueOnEmpty_isAPremultipliedCopy() throws {
        let result = try single([bitmap([255], width: 1, height: 1, color: 0x0000FF7F, x: 0, y: 0)])
        XCTAssertEqual(bytes(result.image), [128, 0, 0, 128])
    }

    func test_nearbyBitmaps_shareOneRegion() throws {
        let result = try single([
            bitmap([255], width: 1, height: 1, color: 0xFFFFFF00, x: 10, y: 10),
            bitmap([255], width: 1, height: 1, color: 0xFFFFFF00, x: 12, y: 13)
        ])
        XCTAssertEqual(result.rect, CGRect(x: 10, y: 10, width: 3, height: 4))
    }

    func test_topSignAndBottomDialogue_getSeparateSmallBuffers() {
        let regions = ASSCompositor.composite([
            bitmap([255], width: 1, height: 1, color: 0xFFFFFF00, x: 100, y: 50),
            bitmap([255], width: 1, height: 1, color: 0xFFFFFF00, x: 1800, y: 2000)
        ])
        XCTAssertEqual(regions.map(\.rect), [CGRect(x: 100, y: 50, width: 1, height: 1),
                                             CGRect(x: 1800, y: 2000, width: 1, height: 1)])
    }

    func test_stride_skipsPaddingBytes() throws {
        // Two rows, one visible pixel each, three padding bytes per row.
        let result = try single([
            bitmap([255, 9, 9, 9, 0, 9, 9, 9], width: 1, height: 2, stride: 4, color: 0xFFFFFF00, x: 0, y: 0)
        ])
        XCTAssertEqual(bytes(result.image), [255, 255, 255, 255, 0, 0, 0, 0])
    }

    // MARK: Regions

    func test_regions_neverExceedFourAndCoverEveryRect() {
        // A 5 x 5 lattice far apart: 25 isolated rects.
        let rects = (0..<25).map { CGRect(x: ($0 % 5) * 500, y: ($0 / 5) * 400, width: 40, height: 20) }
        let regions = ASSCompositor.regions(rects)
        XCTAssertLessThanOrEqual(regions.count, 4)
        XCTAssertEqual(regions.flatMap(\.members).sorted(), Array(0..<25))
        for region in regions {
            for member in region.members { XCTAssertTrue(region.rect.contains(rects[member])) }
        }
        for a in regions.indices {
            for b in regions.indices where b > a { XCTAssertFalse(regions[a].rect.intersects(regions[b].rect)) }
        }
    }

    func test_regions_mergeWhenAGrownUnionReachesANeighbour() {
        // 0 and 2 are far apart until 1 bridges them.
        let rects = [CGRect(x: 0, y: 0, width: 10, height: 10),
                     CGRect(x: 200, y: 0, width: 10, height: 10),
                     CGRect(x: 20, y: 0, width: 170, height: 10)]
        let regions = ASSCompositor.regions(rects)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].members, [0, 1, 2], "members keep paint order")
    }

    func test_regions_keepsDistantGroupsApart() {
        let rects = [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 0, y: 1000, width: 10, height: 10)]
        XCTAssertEqual(ASSCompositor.regions(rects).count, 2)
    }
}
