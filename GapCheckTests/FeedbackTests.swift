import XCTest
@testable import GapCheck

final class FeedbackTests: XCTestCase {
    private let stale: [Side: DirectionState] = [.left: .unknown(.stale), .right: .unknown(.stale)]

    func testClearCopy() {
        XCTAssertEqual(Strings.sentence(.left, .clear), "No cars seen left")
    }

    func testApproachingCopy() {
        XCTAssertEqual(Strings.sentence(.right, .approaching(seconds: 4)), "Car right, about 4 seconds")
        XCTAssertEqual(Strings.sentence(.right, .approaching(seconds: 1)), "Car right, about 1 second")
        XCTAssertEqual(Strings.sentence(.right, .approaching(seconds: nil)), "Car right, far")
    }

    func testUnknownCopy() {
        XCTAssertEqual(Strings.sentence(.left, .unknown(.stale)), "Left camera stopped")
        XCTAssertEqual(Strings.sentence(.left, .unknown(.notLevel)), "Hold the phone level")
        XCTAssertEqual(Strings.sentence(.left, .unknown(.tooDark)), "Left camera too dark")
        XCTAssertEqual(Strings.sentence(.left, .unknown(.tooBright)), "Left camera too bright")
        XCTAssertEqual(Strings.sentence(.right, .unknown(.covered)), "Right camera covered")
        XCTAssertEqual(Strings.sentence(.left, .unknown(.viewBlocked)), "Left view blocked")
    }

    func testNoChangeGivesNothing() {
        let s: [Side: DirectionState] = [.left: .clear, .right: .approaching(seconds: 6)]
        XCTAssertNil(announce(previous: s, current: s))
        XCTAssertNil(announce(previous: s, current: [.left: .clear, .right: .approaching(seconds: 5)]))
    }

    func testFarToTimedIsAChange() {
        XCTAssertEqual(announce(previous: [.left: .approaching(seconds: nil), .right: .clear],
                                current: [.left: .approaching(seconds: 7), .right: .clear]),
                       FeedbackEvent(haptic: .approaching, text: "Car left, about 7 seconds"))
    }

    func testEachStateGivesItsHaptic() {
        XCTAssertEqual(announce(previous: stale, current: [.left: .clear, .right: .unknown(.stale)])?.haptic, .clear)
        XCTAssertEqual(announce(previous: stale, current: [.left: .unknown(.covered), .right: .unknown(.stale)])?.haptic, .unknown)
        XCTAssertEqual(announce(previous: stale, current: [.left: .approaching(seconds: 3), .right: .unknown(.stale)])?.haptic, .approaching)
    }

    func testBothChangedOneSentence() {
        XCTAssertEqual(announce(previous: [.left: .clear, .right: .unknown(.stale)],
                                current: [.left: .approaching(seconds: 6), .right: .clear]),
                       FeedbackEvent(haptic: .approaching, text: "Car left, about 6 seconds. No cars seen right"))
    }

    func testSameSentenceBothSidesSpokenOnce() {
        XCTAssertEqual(announce(previous: [.left: .clear, .right: .clear],
                                current: [.left: .unknown(.notLevel), .right: .unknown(.notLevel)]),
                       FeedbackEvent(haptic: .unknown, text: "Hold the phone level"))
    }

    func testTonePansToNearestCar() {
        let t = toneSettings(states: [.left: .approaching(seconds: 12), .right: .approaching(seconds: 4)],
                             isLevel: true, tiltErrorDegrees: 0)
        XCTAssertTrue(t.isOn)
        XCTAssertEqual(t.pan, 1)
        XCTAssertEqual(t.frequencyHz, Config.approachMinHz + (Config.approachMaxHz - Config.approachMinHz) * (1 - 4.0 / 20), accuracy: 0.001)
    }

    func testToneSilentWhenClear() {
        XCTAssertFalse(toneSettings(states: [.left: .clear, .right: .clear], isLevel: true, tiltErrorDegrees: 0).isOn)
    }

    func testAimingToneRisesTowardLevel() {
        let notLevel: [Side: DirectionState] = [.left: .unknown(.notLevel), .right: .unknown(.notLevel)]
        let far = toneSettings(states: notLevel, isLevel: false, tiltErrorDegrees: 40)
        let near = toneSettings(states: notLevel, isLevel: false, tiltErrorDegrees: 12)
        XCTAssertTrue(far.isOn)
        XCTAssertEqual(far.pan, 0)
        XCTAssertGreaterThan(near.frequencyHz, far.frequencyHz)
        XCTAssertTrue((Config.aimMinHz...Config.aimMaxHz).contains(near.frequencyHz))
    }
}
