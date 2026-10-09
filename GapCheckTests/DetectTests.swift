import CoreML
import Vision
import XCTest
@testable import GapCheck

final class DetectTests: XCTestCase {
    func testModelLoads() {
        XCTAssertNoThrow(try VNCoreMLModel(for: yolo11n(configuration: .init()).model))
    }

    func testBlackFrameIsDarkAndFlat() {
        let q = imageQuality(makeLumaBuffer(width: 1920, height: 1080) { _, _ in 0 })
        XCTAssertLessThan(q.meanLuma, 0.08)
        XCTAssertLessThan(q.laplacianVariance, Config.minLaplacianVariance)
    }

    func testWhiteFrameIsBright() {
        XCTAssertGreaterThan(imageQuality(makeLumaBuffer(width: 1920, height: 1080) { _, _ in 255 }).meanLuma, 0.95)
    }

    func testNoiseFrameIsSharp() {
        var rng = SplitMix64(state: 1)
        let q = imageQuality(makeLumaBuffer(width: 1920, height: 1080) { _, _ in UInt8.random(in: 0...255, using: &rng) })
        XCTAssertGreaterThan(q.laplacianVariance, Config.minLaplacianVariance)
        XCTAssertEqual(q.meanLuma, 0.5, accuracy: 0.05)
    }

    func testTileRectIsCentered640Square() {
        let t = tileRect(orientedWidthPixels: 1080, orientedHeightPixels: 1920)
        XCTAssertEqual(t.minX, (1 - 640.0 / 1080) / 2, accuracy: 1e-9)
        XCTAssertEqual(t.minY, (1 - 640.0 / 1920) / 2, accuracy: 1e-9)
        XCTAssertEqual(t.width, 640.0 / 1080, accuracy: 1e-9)
        XCTAssertEqual(t.height, 640.0 / 1920, accuracy: 1e-9)
    }

    /// Footage smaller than the tile must still be analyzed: Vision rejects a region of interest outside the image.
    func testTileRectClampsToSmallFrames() {
        XCTAssertEqual(tileRect(orientedWidthPixels: 640, orientedHeightPixels: 360), CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testMapFromTile() {
        let tile = tileRect(orientedWidthPixels: 1080, orientedHeightPixels: 1920)
        XCTAssertEqual(mapFromTile(CGRect(x: 0, y: 0, width: 1, height: 1), tile: tile), tile)
        let m = mapFromTile(CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1), tile: tile)
        XCTAssertEqual(m.minX, tile.minX + 0.5 * tile.width, accuracy: 1e-9)
        XCTAssertEqual(m.height, 0.1 * tile.height, accuracy: 1e-9)
    }


    func testMergeKeepsInteriorTileBox() {
        let tile = tileRect(orientedWidthPixels: 1080, orientedHeightPixels: 1920)
        let whole = car(CGRect(x: 0.45, y: 0.45, width: 0.05, height: 0.03))
        let inTile = car(CGRect(x: 0.451, y: 0.451, width: 0.048, height: 0.029))
        XCTAssertEqual(merge(whole: [whole], tile: [inTile], tileRect: tile), [inTile])
    }

    func testMergeDropsEdgeTouchingTileBox() {
        let tile = tileRect(orientedWidthPixels: 1080, orientedHeightPixels: 1920)
        let whole = car(CGRect(x: tile.minX - 0.01, y: 0.45, width: 0.04, height: 0.03))
        let cut = car(CGRect(x: tile.minX, y: 0.45, width: 0.03, height: 0.03))
        XCTAssertEqual(merge(whole: [whole], tile: [cut], tileRect: tile), [whole])
    }

    func testMergeKeepsDisjointBoxes() {
        let tile = tileRect(orientedWidthPixels: 1080, orientedHeightPixels: 1920)
        let a = car(CGRect(x: 0.05, y: 0.05, width: 0.05, height: 0.05))
        let b = car(CGRect(x: 0.45, y: 0.45, width: 0.05, height: 0.05))
        XCTAssertEqual(merge(whole: [a], tile: [b], tileRect: tile).count, 2)
    }

    /// A model whose output isn't object observations must fail the frame (→ stale), not read as "no cars".
    func testUnexpectedResultsThrow() throws {
        XCTAssertThrowsError(try vehicles([VNDetectedObjectObservation(boundingBox: .zero)]))
        XCTAssertThrowsError(try vehicles(nil))
        XCTAssertEqual(try vehicles([]), [])
    }

    func testDetectRunsOnBlankFrame() throws {
        let frame = makeFrame(makeLumaBuffer(width: 1920, height: 1080) { _, _ in 0 })
        XCTAssertEqual(try Detector().detect(frame), [])
    }
}
