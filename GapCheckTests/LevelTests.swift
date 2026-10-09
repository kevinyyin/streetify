import AVFoundation
import XCTest
@testable import GapCheck

final class LevelTests: XCTestCase {
    private func rad(_ degrees: Double) -> Double { degrees * .pi / 180 }

    func testUprightPortraitIsLevel() {
        let a = attitude(gravityX: 0, gravityY: -1, gravityZ: 0)
        XCTAssertEqual(a.hold, .portrait)
        XCTAssertTrue(a.isLevel)
    }

    func testLandscapeHoldsAreDetected() {
        XCTAssertEqual(attitude(gravityX: -1, gravityY: 0, gravityZ: 0).hold, .landscapeLeft)
        XCTAssertEqual(attitude(gravityX: 1, gravityY: 0, gravityZ: 0).hold, .landscapeRight)
        XCTAssertTrue(attitude(gravityX: 1, gravityY: 0, gravityZ: 0).isLevel)
    }

    func testPitchTolerance() {
        XCTAssertTrue(attitude(gravityX: 0, gravityY: -cos(rad(7)), gravityZ: sin(rad(7))).isLevel)
        XCTAssertFalse(attitude(gravityX: 0, gravityY: -cos(rad(9)), gravityZ: sin(rad(9))).isLevel)
    }

    func testRollTolerance() {
        XCTAssertTrue(attitude(gravityX: sin(rad(9)), gravityY: -cos(rad(9)), gravityZ: 0).isLevel)
        XCTAssertFalse(attitude(gravityX: sin(rad(11)), gravityY: -cos(rad(11)), gravityZ: 0).isLevel)
    }

    func testBetweenHoldsIsNotLevel() {
        XCTAssertFalse(attitude(gravityX: -0.707, gravityY: -0.707, gravityZ: 0).isLevel)
    }

    func testTiltErrorIsLargerOfPitchAndRoll() {
        let a = attitude(gravityX: sin(rad(5)), gravityY: -cos(rad(5)), gravityZ: 0)
        XCTAssertEqual(a.tiltErrorDegrees, 5, accuracy: 0.01)
    }

    func testExifOrientation() {
        XCTAssertEqual(exifOrientation(hold: .portrait, position: .back), .right)
        XCTAssertEqual(exifOrientation(hold: .portrait, position: .front), .leftMirrored)
    }
}
