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
        let s: [Side: DirectionState] = [.left: .clear, .right: .approaching(.seconds(9))]
        XCTAssertNil(announce(previous: s, current: s))
        XCTAssertNil(announce(previous: s, current: [.left: .clear, .right: .approaching(.seconds(8))]))
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

    /// Not level is the tone's job: no speech, no vibration. Leveling out always gets the status announced.
    func testNotLevelIsSilentButLevelingOutIsAnnounced() {
        let clear: [Side: DirectionState] = [.left: .clear, .right: .clear]
        let tilted: [Side: DirectionState] = [.left: .unknown(.notLevel), .right: .unknown(.notLevel)]
        XCTAssertNil(announce(previous: clear, current: tilted))
        XCTAssertEqual(announce(previous: announcedBaseline(previous: clear, current: tilted), current: clear),
                       FeedbackEvent(haptic: .clear, text: "No cars seen left. No cars seen right"))
    }

    /// One extra warning when a car gets close; a wobbling estimate doesn't repeat it.
    func testCloseWarningSpokenOnce() {
        let at12: [Side: DirectionState] = [.left: .approaching(.seconds(12)), .right: .clear]
        let at4: [Side: DirectionState] = [.left: .approaching(.seconds(4)), .right: .clear]
        let at6: [Side: DirectionState] = [.left: .approaching(.seconds(6)), .right: .clear]
        XCTAssertEqual(announce(previous: at12, current: at4), FeedbackEvent(haptic: .approaching, text: "Car left, about 4 seconds"))
        var baseline = announcedBaseline(previous: at12, current: at4)
        XCTAssertNil(announce(previous: baseline, current: at6))
        baseline = announcedBaseline(previous: baseline, current: at6)
        XCTAssertNil(announce(previous: baseline, current: at4))
    }

    /// The one exception to "nothing spoken while tilted": a stopped camera.
    func testCameraStoppedIsSpokenWhileTilted() {
        XCTAssertEqual(announce(previous: [.left: .unknown(.notLevel), .right: .unknown(.notLevel)],
                                current: [.left: .unknown(.stale), .right: .unknown(.notLevel)])?.text,
                       "Left camera stopped")
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
        tone.apply(ToneSettings(isOn: true, frequencyHz: 300))
        XCTAssertTrue(tone.engine.isRunning)
    }

    /// The tone only means "not level": silent whenever the phone is level, cars or not.
    func testToneOffWhenLevel() {
        XCTAssertFalse(toneSettings(isLevel: true, tiltErrorDegrees: 0).isOn)
    }

    func testAimingToneRisesTowardLevel() {
        let far = toneSettings(isLevel: false, tiltErrorDegrees: 40)
        let near = toneSettings(isLevel: false, tiltErrorDegrees: 12)
        XCTAssertTrue(far.isOn)
        XCTAssertGreaterThan(near.frequencyHz, far.frequencyHz)
        XCTAssertTrue((Config.aimMinHz...Config.aimMaxHz).contains(near.frequencyHz))
    }
}
