import XCTest
@testable import GapCheck

final class FeedbackTests: XCTestCase {
    private let stale: [Side: DirectionState] = [.left: .unknown(.stale), .right: .unknown(.stale)]

    func testClearCopy() {
        XCTAssertEqual(Strings.sentence(.left, .clear), "No cars seen left")
    }

    func testApproachingCopy() {
        XCTAssertEqual(Strings.sentence(.right, .approaching(.seconds(4))), "Car right, about 4 seconds")
        XCTAssertEqual(Strings.sentence(.right, .approaching(.seconds(1))), "Car right, about 1 second")
        XCTAssertEqual(Strings.sentence(.right, .approaching(.far)), "Car right, far")
        XCTAssertEqual(Strings.sentence(.right, .approaching(.unmeasured)), "Car right")
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
        let s: [Side: DirectionState] = [.left: .clear, .right: .approaching(.seconds(6))]
        XCTAssertNil(announce(previous: s, current: s))
        XCTAssertNil(announce(previous: s, current: [.left: .clear, .right: .approaching(.seconds(5))]))
    }

    func testFarToTimedIsAChange() {
        XCTAssertEqual(announce(previous: [.left: .approaching(.far), .right: .clear],
                                current: [.left: .approaching(.seconds(7)), .right: .clear]),
                       FeedbackEvent(haptic: .approaching, text: "Car left, about 7 seconds"))
    }

    /// A car hovering near the window edge must not flip "far" / "about 19 seconds" over and over.
    func testTimedToFarIsSilent() {
        let timed: [Side: DirectionState] = [.left: .approaching(.seconds(19)), .right: .clear]
        let far: [Side: DirectionState] = [.left: .approaching(.far), .right: .clear]
        XCTAssertNil(announce(previous: timed, current: far))
        let baseline = announcedBaseline(previous: timed, current: far)
        XCTAssertEqual(baseline, timed)
        XCTAssertNil(announce(previous: baseline, current: timed))
    }

    func testEachStateGivesItsHaptic() {
        XCTAssertEqual(announce(previous: [.left: .unknown(.stale), .right: .clear], current: [.left: .clear, .right: .clear])?.haptic, .clear)
        XCTAssertEqual(announce(previous: stale, current: [.left: .unknown(.covered), .right: .unknown(.stale)])?.haptic, .unknown)
        XCTAssertEqual(announce(previous: stale, current: [.left: .approaching(.seconds(3)), .right: .unknown(.stale)])?.haptic, .approaching)
    }

    func testBothChangedOneSentence() {
        XCTAssertEqual(announce(previous: [.left: .clear, .right: .unknown(.stale)],
                                current: [.left: .approaching(.seconds(6)), .right: .clear]),
                       FeedbackEvent(haptic: .approaching, text: "Car left, about 6 seconds. No cars seen right"))
    }

    func testSameSentenceBothSidesSpokenOnce() {
        XCTAssertEqual(announce(previous: [.left: .clear, .right: .clear],
                                current: [.left: .unknown(.notLevel), .right: .unknown(.notLevel)]),
                       FeedbackEvent(haptic: .unknown, text: "Hold the phone level"))
    }

    /// Approaching and Unknown override Clear: a side going clear must not replace the other side's warning.
    func testClearDoesNotDropOtherSidesWarning() {
        XCTAssertEqual(announce(previous: [.left: .approaching(.seconds(1)), .right: .approaching(.seconds(6))],
                                current: [.left: .clear, .right: .approaching(.seconds(5))]),
                       FeedbackEvent(haptic: .approaching, text: "No cars seen left. Car right, about 5 seconds"))
        XCTAssertEqual(announce(previous: [.left: .approaching(.seconds(2)), .right: .unknown(.covered)],
                                current: [.left: .clear, .right: .unknown(.covered)]),
                       FeedbackEvent(haptic: .unknown, text: "No cars seen left. Right camera covered"))
    }

    /// A side still in its initial stale state after startup was never announced; the baseline forgets it so it is.
    func testUnstartedSideIsAnnouncedAfterStartup() {
        let states: [Side: DirectionState] = [.left: .unknown(.stale), .right: .clear]
        XCTAssertEqual(announce(previous: baselineAfterStartup(states), current: states),
                       FeedbackEvent(haptic: .unknown, text: "Left camera stopped"))
    }

    /// A route change or interruption stops the audio engine; the next update must bring the tone back.
    func testToneRestartsWhenEngineStops() {
        let tone = Tone()
        tone.engine.stop()
        tone.apply(ToneSettings(isOn: true, frequencyHz: 600, pan: 0))
        XCTAssertTrue(tone.engine.isRunning)
    }

    func testTonePansToNearestCar() {
        let t = toneSettings(states: [.left: .approaching(.seconds(12)), .right: .approaching(.seconds(4))],
                             isLevel: true, tiltErrorDegrees: 0)
        XCTAssertTrue(t.isOn)
        XCTAssertEqual(t.pan, 1)
        XCTAssertEqual(t.frequencyHz, Config.approachMinHz + (Config.approachMaxHz - Config.approachMinHz) * (1 - 4.0 / 20), accuracy: 0.001)
    }

    func testUnmeasuredCarGetsMidPitch() {
        let t = toneSettings(states: [.left: .approaching(.unmeasured), .right: .clear], isLevel: true, tiltErrorDegrees: 0)
        XCTAssertEqual(t.frequencyHz, (Config.approachMinHz + Config.approachMaxHz) / 2, accuracy: 0.001)
        XCTAssertEqual(t.pan, -1)
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
