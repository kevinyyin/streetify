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

    func testDetectRunsOnBlankFrame() throws {
        let frame = makeFrame(makeLumaBuffer(width: 1920, height: 1080) { _, _ in 0 })
        XCTAssertEqual(try Detector().detect(frame), [])
    }
}
