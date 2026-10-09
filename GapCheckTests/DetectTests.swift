import CoreML
import Vision
import XCTest
@testable import GapCheck

final class DetectTests: XCTestCase {
    func testModelLoads() {
        XCTAssertNoThrow(try VNCoreMLModel(for: yolo11n(configuration: .init()).model))
    }
}
