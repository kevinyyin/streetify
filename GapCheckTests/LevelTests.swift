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

    /// Upright portrait, dip 60°: back camera looking east reads 90°, looking north reads 0°.
    func testCameraHeadingFromGravityAndField() throws {
        let c = cos(rad(60)), s = sin(rad(60))
        let east = try XCTUnwrap(cameraHeadingDegrees(gravity: (0, -1, 0), field: (-c, -s, 0)))
        XCTAssertEqual(east, 90, accuracy: 1e-6)
        let north = try XCTUnwrap(cameraHeadingDegrees(gravity: (0, -1, 0), field: (0, -s, -c)))
        XCTAssertEqual(north, 0, accuracy: 1e-6)
        XCTAssertNil(cameraHeadingDegrees(gravity: (0, 0, -1), field: (0, c, -s)), "camera pointing at the ground")
    }

    func testAngleDifferenceWraps() {
        XCTAssertEqual(angleDifferenceDegrees(350, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(angleDifferenceDegrees(90, 270), 180, accuracy: 1e-9)
    }

    func testExifOrientation() {
        XCTAssertEqual(exifOrientation(hold: .portrait, position: .back), .right)
        XCTAssertEqual(exifOrientation(hold: .portrait, position: .front), .leftMirrored)
    }
}

final class VideoOrientationTests: XCTestCase {
    func testVideoOrientationFromTransform() {
        XCTAssertEqual(videoOrientation(CGAffineTransform.identity), .up)
        XCTAssertEqual(videoOrientation(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)), .right)
        XCTAssertEqual(videoOrientation(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)), .left)
        XCTAssertEqual(videoOrientation(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)), .down)
    }
}

final class LevelBufferTests: XCTestCase {
    /// A wobble near the 8° limit must not flip level/not level every frame.
    func testLevelBufferStopsFlipping() {
        var wasLevel = true
        let results = [7.0, 9.0, 7.0, 5.0].map { degrees -> Bool in
            let p = degrees * .pi / 180
            wasLevel = isLevel(attitude(gravityX: 0, gravityY: -cos(p), gravityZ: sin(p)), wasLevel: wasLevel)
            return wasLevel
        }
        XCTAssertEqual(results, [true, false, false, true])
    }

    /// Both cameras share one buffer, so a dip only one of them sampled can't leave them disagreeing.
    func testSharedLevelGateKeepsCamerasInAgreement() {
        func reading(_ degrees: Double) -> Attitude {
            let p = degrees * .pi / 180
            return attitude(gravityX: 0, gravityY: -cos(p), gravityZ: sin(p))
        }
        let gate = LevelGate()
        XCTAssertFalse(gate.update(reading(20))) // front
        XCTAssertTrue(gate.update(reading(5)))   // front catches the dip back to level
        XCTAssertTrue(gate.update(reading(7)))   // back missed the dip, and agrees anyway
        XCTAssertFalse(gate.update(nil))         // no motion data: not level
    }
}
