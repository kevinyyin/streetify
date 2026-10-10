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
        XCTAssertEqual(Strings.sentence(.left, .unknown(.noPermission)), "Camera access is off. Turn it on in Settings")
        XCTAssertEqual(Strings.sentence(.left, .unknown(.unsupported)), "This iPhone can't use both cameras")
        XCTAssertEqual(Strings.sentence(.right, .unknown(.interrupted)), "Right: camera in use")
        XCTAssertEqual(Strings.sentence(.left, .unknown(.overheated)), "Phone too hot")
        XCTAssertEqual(Strings.sentence(.right, .unknown(.noRoadSeen)), "Right: no road seen")
    }

    /// An arrival under a second is "close", never "0 seconds".
    func testCloseCopy() {
        XCTAssertEqual(Strings.sentence(.left, .approaching(.seconds(0))), "Left: car, close")
        XCTAssertEqual(Strings.label(.approaching(.seconds(0))), "Car · close")
    }

    /// Phone-wide news is the same sentence for both sides: it is said once.
    func testSameSentenceForBothSidesIsSaidOnce() {
        let e = announce(previous: stale, current: [.left: .unknown(.overheated), .right: .unknown(.overheated)])
        XCTAssertEqual(e?.text, "Phone too hot")
        XCTAssertEqual(e?.haptic, .unknown)
    }

    func testPreviewOffForVoiceOverUnlessAsked() {
        XCTAssertTrue(showsPreview(voiceOverRunning: false, arguments: ["GapCheck"]))
        XCTAssertFalse(showsPreview(voiceOverRunning: true, arguments: ["GapCheck"]))
        XCTAssertTrue(showsPreview(voiceOverRunning: true, arguments: ["GapCheck", "-showOverlay"]))
    }

    /// The big words on each side's banner. Like speech, nothing reads as "go".
    func testBannerLabels() {
        XCTAssertEqual(Strings.label(.clear), "No cars")
        XCTAssertEqual(Strings.label(.approaching(.seconds(6))), "Car · 6 s")
        XCTAssertEqual(Strings.label(.approaching(.far)), "Car · far")
        XCTAssertEqual(Strings.label(.approaching(.unmeasured)), "Car")
        XCTAssertEqual(Strings.label(.unknown(.stale)), "Camera stopped")
        XCTAssertEqual(Strings.label(.unknown(.notLevel)), "Hold level")
        XCTAssertEqual(Strings.label(.unknown(.tooDark)), "Too dark")
        XCTAssertEqual(Strings.label(.unknown(.tooBright)), "Too bright")
        XCTAssertEqual(Strings.label(.unknown(.covered)), "Camera covered")
        XCTAssertEqual(Strings.label(.unknown(.viewBlocked)), "Blocked")
        XCTAssertEqual(Strings.label(.unknown(.noPermission)), "Camera off in Settings")
        XCTAssertEqual(Strings.label(.unknown(.unsupported)), "Not supported")
        XCTAssertEqual(Strings.label(.unknown(.interrupted)), "Camera in use")
        XCTAssertEqual(Strings.label(.unknown(.overheated)), "Too hot")
        XCTAssertEqual(Strings.label(.unknown(.noRoadSeen)), "No road seen")
        XCTAssertEqual(priority(of: .approaching(.far)), .car)
        XCTAssertEqual(priority(of: .unknown(.notLevel)), .problem)
        XCTAssertEqual(priority(of: .clear), .noCars)
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

/// Invariant 1: nothing the app says or shows reads as permission to cross.
final class BannedWordsTests: XCTestCase {
    func testNoSentenceOrLabelSaysGo() throws {
        let reasons: [UnknownReason] = [.stale, .notLevel, .tooDark, .tooBright, .covered, .viewBlocked, .noPermission,
                                        .unsupported, .interrupted, .overheated, .noRoadSeen]
        let arrivals: [Arrival] = [.seconds(0), .seconds(1), .seconds(7), .far, .unmeasured]
        let states: [DirectionState] = [.clear] + reasons.map { .unknown($0) } + arrivals.map { .approaching($0) }
        var texts = [Strings.paused, Strings.holdInstructions]
        for state in states {
            texts += [Strings.sentence(.left, state), Strings.sentence(.right, state), Strings.label(state)]
        }
        texts.append(Strings.status([.left: .clear, .right: .clear]))
        let banned = try NSRegularExpression(pattern: #"\b(safe|go|cross now|clear to cross|all clear)\b"#, options: .caseInsensitive)
        for text in texts {
            XCTAssertNil(banned.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), text)
        }
    }
}

/// One sentence at a time: a car is never cut off, more urgent news cuts in, the rest waits (newest per side) and is
/// said as it is when its turn comes.
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

    /// Newer news about the side being spoken waits instead of cutting in, so a stream of cars is not a stream of
    /// cut-off sentences.
    func testSameSideNewsWaits() {
        var q = SpeechQueue()
        let car9 = utterance(.right, .approaching(.seconds(9)))
        let car8 = utterance(.right, .approaching(.seconds(8))) // not close: a close warning would cut in
        XCTAssertEqual(q.add([car9], atSeconds: 0), car9)
        XCTAssertNil(q.add([car8], atSeconds: 0.5))
        XCTAssertEqual(q.finished(text: car9.text, atSeconds: 1.5), car8)
    }

    /// A sentence that waited is said as its side is now: cars that already passed are dropped.
    func testWaitingCarIsRefreshedWhenItsTurnComes() {
        var q = SpeechQueue()
        _ = q.add([carRight], atSeconds: 0)
        XCTAssertNil(q.add([utterance(.right, .approaching(.seconds(8)))], atSeconds: 0.5)) // not close, so it waits
        let next = q.finished(text: carRight.text, atSeconds: 1.5, current: [.right: .clear])
        XCTAssertEqual(next?.text, "Right: no cars")
    }

    /// Nothing is said when the refreshed sentence is what the user just heard.
    func testWaitingSentenceThatIsNoLongerNewsIsDropped() {
        var q = SpeechQueue()
        _ = q.add([carRight], atSeconds: 0, current: [.right: .approaching(.seconds(6))])
        XCTAssertNil(q.add([utterance(.right, .clear)], atSeconds: 0.5))
        XCTAssertNil(q.finished(text: carRight.text, atSeconds: 1.5, current: [.right: .approaching(.seconds(6))]))
    }

    /// The state after leveling out is always said, even when it matches what was said before the tilt.
    func testSameSentenceAfterLevelingIsSaidAgain() {
        var q = SpeechQueue()
        let noCars = utterance(.left, .clear)
        XCTAssertEqual(q.add([noCars], atSeconds: 0, current: [.left: .clear]), noCars)
        XCTAssertNil(q.finished(text: noCars.text, atSeconds: 1, current: [.left: .clear]))
        XCTAssertEqual(q.add([noCars], atSeconds: 5, current: [.left: .clear]), noCars) // announce() sends it again
    }

    /// A close warning cuts in, even on the side being spoken: it can't wait behind older news about that car.
    func testCloseWarningCutsInOnTheSameSide() {
        var q = SpeechQueue()
        let car12 = utterance(.right, .approaching(.seconds(12)))
        let car4 = utterance(.right, .approaching(.seconds(4)))
        XCTAssertEqual(q.add([car12], atSeconds: 0), car12)
        XCTAssertEqual(q.add([car4], atSeconds: 0.5), car4)
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

/// Screen tints: red sticks to a close car until it leaves or stands still, and spreads to the line behind it.
final class HighlightTests: XCTestCase {
    /// Tall, close, and surely coming.
    private func close(id: Int = 1) -> Track {
        var t = makeTrack(approachingHeights(tauAtEndSeconds: 5, heightAtEnd: 0.2), id: id)
        t.directionBoxes = trackWithDirection(heightAt: { 0.1 * (1 + 0.25 * $0) }).directionBoxes
        return t
    }
    /// Smaller, surely coming, far off.
    private let comingBehind = trackWithDirection(heightAt: { 0.03 * (1 + 0.1 * $0) }, id: 2)
    private let parkedBehind = trackWithDirection(heightAt: { _ in 0.05 }, id: 3)

    func testCloseCarIsRed() {
        XCTAssertEqual(redTrackIds([close()], atSeconds: 4, wasRed: []), [1])
    }

    func testCarComingBehindARedCarIsRedButAParkedOneIsNot() {
        XCTAssertEqual(redTrackIds([comingBehind, parkedBehind, close()], atSeconds: 4, wasRed: []), [1, 2])
        XCTAssertEqual(redTrackIds([comingBehind], atSeconds: 4, wasRed: []), [], "far and alone: yellow")
    }

    func testRedStaysUntilStandstillWithNothingRedInFront() {
        let stopped = trackWithDirection(heightAt: { _ in 0.05 }, id: 7)
        XCTAssertEqual(redTrackIds([stopped], atSeconds: 4, wasRed: [7]), [])
        XCTAssertEqual(redTrackIds([stopped, close()], atSeconds: 4, wasRed: [7]), [1, 7])
        var crossing = trackWithDirection(heightAt: { _ in 0.1 }, id: 8)
        crossing.directionBoxes = crossing.directionBoxes.map { ($0.t, $0.box.offsetBy(dx: 0.1 * $0.t, dy: 0)) }
        XCTAssertEqual(redTrackIds([crossing], atSeconds: 4, wasRed: [8]), [8], "still moving: stays red")
    }

    func testTints() {
        XCTAssertEqual(highlight(close(), isRed: true), .danger)
        XCTAssertEqual(highlight(parkedBehind, isRed: false), .facing)
        XCTAssertEqual(highlight(trackWithDirection(heightAt: { 0.08 * (1 - 0.06 * $0) }), isRed: false), .away)
    }
}

/// Late outlines are moved with their car.
final class MaskAlignmentTests: XCTestCase {
    func testMaskIsCarriedWithItsCar() {
        let old = CGRect(x: 0.2, y: 0.4, width: 0.2, height: 0.1)
        let new = CGRect(x: 0.5, y: 0.4, width: 0.4, height: 0.2) // moved right and twice as close
        let mask = CGRect(x: 0.25, y: 0.42, width: 0.1, height: 0.05)
        let moved = carried(mask, from: old, to: new)
        XCTAssertEqual(moved.minX, 0.6, accuracy: 1e-9)
        XCTAssertEqual(moved.minY, 0.44, accuracy: 1e-9)
        XCTAssertEqual(moved.width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(moved.height, 0.1, accuracy: 1e-9)
    }

    func testBoxAtAnEarlierFrame() {
        var track = trackWithDirection(heightAt: { _ in 0.1 })
        track.directionBoxes = (0...10).map { i in (Double(i) / 10, CGRect(x: Double(i) / 100, y: 0, width: 0.1, height: 0.1)) }
        XCTAssertEqual(track.box(atSeconds: 0.5)?.minX ?? -1, 0.05, accuracy: 1e-9)
        XCTAssertNil(track.box(atSeconds: 5))
    }
}
