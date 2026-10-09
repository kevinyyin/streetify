import XCTest
@testable import GapCheck

final class FeedbackTests: XCTestCase {
    private let stale: [Side: DirectionState] = [.left: .unknown(.stale), .right: .unknown(.stale)]

    func testClearCopy() {
        XCTAssertEqual(Strings.sentence(.left, .clear), "Left: no cars")
    }

    func testApproachingCopy() {
        XCTAssertEqual(Strings.sentence(.right, .approaching(.seconds(4))), "Right: car, 4 seconds")
        XCTAssertEqual(Strings.sentence(.right, .approaching(.seconds(1))), "Right: car, 1 second")
        XCTAssertEqual(Strings.sentence(.right, .approaching(.far)), "Right: car, far")
        XCTAssertEqual(Strings.sentence(.right, .approaching(.unmeasured)), "Right: car")
    }

    func testUnknownCopy() {
        XCTAssertEqual(Strings.sentence(.left, .unknown(.stale)), "Left: camera stopped")
        XCTAssertEqual(Strings.sentence(.left, .unknown(.notLevel)), "Hold the phone level")
        XCTAssertEqual(Strings.sentence(.left, .unknown(.tooDark)), "Left: too dark")
        XCTAssertEqual(Strings.sentence(.left, .unknown(.tooBright)), "Left: too bright")
        XCTAssertEqual(Strings.sentence(.right, .unknown(.covered)), "Right: camera covered")
        XCTAssertEqual(Strings.sentence(.left, .unknown(.viewBlocked)), "Left: blocked")
    }

    /// What the single VoiceOver status item reads, and what a tap on the screen speaks.
    func testStatusSentence() {
        XCTAssertEqual(Strings.status([.left: .clear, .right: .approaching(.seconds(6))]), "Left: no cars. Right: car, 6 seconds")
        XCTAssertEqual(Strings.status([.left: .unknown(.notLevel), .right: .unknown(.notLevel)]), "Hold the phone level")
    }

    func testNoChangeGivesNothing() {
        let s: [Side: DirectionState] = [.left: .clear, .right: .approaching(.seconds(9))]
        XCTAssertNil(announce(previous: s, current: s))
        XCTAssertNil(announce(previous: s, current: [.left: .clear, .right: .approaching(.seconds(8))]))
    }

    func testFarToTimedIsAChange() {
        let e = announce(previous: [.left: .approaching(.far), .right: .clear], current: [.left: .approaching(.seconds(7)), .right: .clear])
        XCTAssertEqual(e?.text, "Left: car, 7 seconds")
        XCTAssertEqual(e?.haptic, .approaching)
    }

    /// A car hovering near the window edge must not flip "far" / "19 seconds" over and over.
    func testTimedToFarIsSilent() {
        let timed: [Side: DirectionState] = [.left: .approaching(.seconds(19)), .right: .clear]
        let far: [Side: DirectionState] = [.left: .approaching(.far), .right: .clear]
        XCTAssertNil(announce(previous: timed, current: far))
        let baseline = announcedBaseline(previous: timed, current: far)
        XCTAssertEqual(baseline, timed)
        XCTAssertNil(announce(previous: baseline, current: timed))
    }

    /// The vibration follows the whole situation: the "no cars" hum only when both sides are clear.
    func testEachStateGivesItsHaptic() {
        XCTAssertEqual(announce(previous: [.left: .unknown(.stale), .right: .clear], current: [.left: .clear, .right: .clear])?.haptic, .clear)
        XCTAssertEqual(announce(previous: stale, current: [.left: .unknown(.covered), .right: .unknown(.stale)])?.haptic, .unknown)
        XCTAssertEqual(announce(previous: stale, current: [.left: .approaching(.seconds(3)), .right: .unknown(.stale)])?.haptic, .approaching)
    }

    /// Left blocked and a car on the right: the car is said first, then the problem.
    func testCarIsSaidFirst() {
        let e = announce(previous: [.left: .clear, .right: .clear],
                         current: [.left: .unknown(.viewBlocked), .right: .approaching(.seconds(6))])
        XCTAssertEqual(e?.utterances.map(\.text), ["Right: car, 6 seconds", "Left: blocked"])
        XCTAssertEqual(e?.utterances.map(\.priority), [.car, .problem])
        XCTAssertEqual(e?.haptic, .approaching)
    }

    /// Not level is the tone's job: no speech, no vibration. Leveling out always gets the status announced.
    func testNotLevelIsSilentButLevelingOutIsAnnounced() {
        let clear: [Side: DirectionState] = [.left: .clear, .right: .clear]
        let tilted: [Side: DirectionState] = [.left: .unknown(.notLevel), .right: .unknown(.notLevel)]
        XCTAssertNil(announce(previous: clear, current: tilted))
        let e = announce(previous: announcedBaseline(previous: clear, current: tilted), current: clear)
        XCTAssertEqual(e?.text, "Left: no cars. Right: no cars")
        XCTAssertEqual(e?.haptic, .clear)
    }

    /// One extra warning when a car gets close; a wobbling estimate doesn't repeat it.
    func testCloseWarningSpokenOnce() {
        let at12: [Side: DirectionState] = [.left: .approaching(.seconds(12)), .right: .clear]
        let at4: [Side: DirectionState] = [.left: .approaching(.seconds(4)), .right: .clear]
        let at6: [Side: DirectionState] = [.left: .approaching(.seconds(6)), .right: .clear]
        XCTAssertEqual(announce(previous: at12, current: at4)?.text, "Left: car, 4 seconds")
        var baseline = announcedBaseline(previous: at12, current: at4)
        XCTAssertNil(announce(previous: baseline, current: at6))
        baseline = announcedBaseline(previous: baseline, current: at6)
        XCTAssertNil(announce(previous: baseline, current: at4))
    }

    /// A second car after a close warning still gets its time and its own close warning.
    func testNextCarAfterCloseWarningIsAnnounced() {
        let carA4: [Side: DirectionState] = [.left: .approaching(.seconds(4)), .right: .clear]
        let carB12: [Side: DirectionState] = [.left: .approaching(.seconds(12)), .right: .clear]
        let carB5: [Side: DirectionState] = [.left: .approaching(.seconds(5)), .right: .clear]
        XCTAssertEqual(announce(previous: carA4, current: carB12)?.text, "Left: car, 12 seconds")
        XCTAssertEqual(announce(previous: announcedBaseline(previous: carA4, current: carB12), current: carB5)?.text, "Left: car, 5 seconds")
        XCTAssertEqual(announce(previous: carA4, current: [.left: .approaching(.far), .right: .clear])?.text, "Left: car, far")
    }

    /// Replay controls only appear when launched from Xcode, so a stray tap can't swap a live camera for a clip.
    func testReplayControlsNeedLaunchArgument() {
        XCTAssertFalse(showsReplayControls(arguments: ["GapCheck"]))
        XCTAssertTrue(showsReplayControls(arguments: ["GapCheck", "-showReplay"]))
    }

    /// The one exception to "nothing spoken while tilted": a stopped camera.
    func testCameraStoppedIsSpokenWhileTilted() {
        XCTAssertEqual(announce(previous: [.left: .unknown(.notLevel), .right: .unknown(.notLevel)],
                                current: [.left: .unknown(.stale), .right: .unknown(.notLevel)])?.text,
                       "Left: camera stopped")
    }

    /// Only the side that changed is spoken; the queue keeps a car warning from being cut off, so no restating.
    func testOnlyChangedSideIsSpoken() {
        let e = announce(previous: [.left: .approaching(.seconds(2)), .right: .approaching(.seconds(6))],
                         current: [.left: .clear, .right: .approaching(.seconds(6))])
        XCTAssertEqual(e?.text, "Left: no cars")
        XCTAssertEqual(e?.haptic, .approaching) // a car is still coming on the right
    }

    /// A side still in its initial stale state after startup was never announced; the baseline forgets it so it is.
    func testUnstartedSideIsAnnouncedAfterStartup() {
        let states: [Side: DirectionState] = [.left: .unknown(.stale), .right: .clear]
        let e = announce(previous: baselineAfterStartup(states), current: states)
        XCTAssertEqual(e?.text, "Left: camera stopped")
        XCTAssertEqual(e?.haptic, .unknown)
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

/// One sentence at a time: a car is never cut off, more urgent news cuts in, the rest waits (newest per side).
final class SpeechQueueTests: XCTestCase {
    private let carRight = utterance(.right, .approaching(.seconds(6)))
    private let blockedLeft = utterance(.left, .unknown(.viewBlocked))

    func testCarInterruptsProblemAndProblemFollows() {
        var q = SpeechQueue()
        XCTAssertEqual(q.add([blockedLeft], atSeconds: 0), blockedLeft)
        XCTAssertEqual(q.add([carRight], atSeconds: 0.5), carRight)
        XCTAssertEqual(q.finished(text: carRight.text, atSeconds: 2), blockedLeft)
    }

    func testProblemWaitsForCar() {
        var q = SpeechQueue()
        XCTAssertEqual(q.add([carRight, blockedLeft], atSeconds: 0), carRight)
        XCTAssertNil(q.add([utterance(.left, .unknown(.covered))], atSeconds: 0.3))
        XCTAssertEqual(q.finished(text: carRight.text, atSeconds: 1.5)?.text, "Left: camera covered")
    }

    func testOnlyNewestPendingPerSide() {
        var q = SpeechQueue()
        XCTAssertEqual(q.add([carRight], atSeconds: 0), carRight)
        XCTAssertNil(q.add([blockedLeft], atSeconds: 0.2))
        XCTAssertNil(q.add([utterance(.left, .clear)], atSeconds: 0.4))
        XCTAssertEqual(q.finished(text: carRight.text, atSeconds: 1.5)?.text, "Left: no cars")
        XCTAssertNil(q.finished(text: "Left: no cars", atSeconds: 2.5))
    }

    func testSameSideNewsInterrupts() {
        var q = SpeechQueue()
        let car9 = utterance(.right, .approaching(.seconds(9)))
        let car5 = utterance(.right, .approaching(.seconds(5)))
        XCTAssertEqual(q.add([car9], atSeconds: 0), car9)
        XCTAssertEqual(q.add([car5], atSeconds: 0.5), car5)
        XCTAssertNil(q.finished(text: car5.text, atSeconds: 1.5))
    }

    /// A late "finished" for a sentence that was cut off must not end the one now playing.
    func testFinishedForAnotherSentenceIsIgnored() {
        var q = SpeechQueue()
        _ = q.add([blockedLeft], atSeconds: 0)
        _ = q.add([carRight], atSeconds: 0.5)
        XCTAssertNil(q.finished(text: blockedLeft.text, atSeconds: 0.6))
        XCTAssertEqual(q.finished(text: carRight.text, atSeconds: 2), blockedLeft)
    }

    /// The status the user asked for covers both sides, so nothing it cut off is repeated after it.
    func testStatusReplacesEverything() {
        var q = SpeechQueue()
        let status = Utterance(side: nil, text: "Left: blocked. Right: car, 6 seconds", priority: .car)
        _ = q.add([carRight], atSeconds: 0)
        XCTAssertNil(q.add([blockedLeft], atSeconds: 0.2))
        XCTAssertEqual(q.add([status], atSeconds: 0.5), status)
        XCTAssertNil(q.finished(text: status.text, atSeconds: 2))
    }

    /// If the phone never reports a sentence finished, the next one plays after Config.maxUtteranceSeconds.
    func testStalledSentenceTimesOut() {
        var q = SpeechQueue()
        _ = q.add([carRight], atSeconds: 0)
        XCTAssertNil(q.add([blockedLeft], atSeconds: 1))
        XCTAssertEqual(q.add([], atSeconds: Config.maxUtteranceSeconds + 0.1), blockedLeft)
    }
}
