import AVFoundation
import XCTest
@testable import GapCheck

final class DecideTests: XCTestCase {
    private let tile = tileRect(orientedWidthPixels: 1080, orientedHeightPixels: 1920)

    private func obs(_ t: Double, level: Bool = true, luma: Double = 0.5, variance: Double = 100,
                     faces: [CGRect] = [], heading: Double? = nil, still: Bool = true) -> FrameObservation {
        FrameObservation(timestampSeconds: t, isLevel: level,
                         quality: ImageQuality(meanLuma: luma, laplacianVariance: variance), tile: tile, faceBoxes: faces,
                         headingDegrees: heading, isStill: still)
    }

    /// A Decider that has already seen a moving car, so an empty road can read "no cars".
    private func seen() -> Decider {
        let d = Decider()
        d.roadSeenSeconds = 0
        return d
    }

    /// Growing over the 4 s direction window, but with flat recent heights: proof of a road, not a warning.
    private var movingTrack: Track { trackWithDirection(heightAt: { 0.05 * (1 + 0.2 * $0) }) }

    /// Clean frames at 10 fps from `from` through `to`; returns the last state.
    @discardableResult
    private func feed(_ d: Decider, from: Double, through to: Double, tracks: [Track] = []) -> DirectionState {
        var s = d.state
        for t in stride(from: from, through: to + 1e-9, by: 0.1) { s = d.update(obs(t), tracks: tracks) }
        return s
    }

    private var approachingTrack: Track { makeTrack(approachingHeights(tauAtEndSeconds: 8.5, heightAtEnd: 0.02)) }

    private func parkedTrack(_ box: CGRect) -> Track {
        makeTrack(parkedHeights(height: box.height, noisePixels: 0, seed: 1), box: box)
    }

    func testInitialStateIsUnknown() {
        XCTAssertEqual(Decider().state, .unknown(.stale))
    }

    func testClearNeedsHold() {
        let d = seen()
        XCTAssertEqual(feed(d, from: 0, through: 1.4), .unknown(.stale))
        XCTAssertEqual(d.update(obs(1.5), tracks: []), .clear)
    }

    /// Invariant 2: frames stop (or every detection throws, so Decide never updates) → Unknown, never Clear.
    func testNoFramesAfterClearGoesStale() {
        let d = seen()
        XCTAssertEqual(feed(d, from: 0, through: 2.0), .clear)
        XCTAssertEqual(d.checkStale(nowSeconds: 2.29), .clear)
        XCTAssertEqual(d.checkStale(nowSeconds: 2.31), .unknown(.stale))
    }

    func testReplayGapIsStale() {
        let d = seen()
        feed(d, from: 0, through: 2.0)
        XCTAssertEqual(d.update(obs(2.5), tracks: []), .unknown(.stale))
        XCTAssertEqual(feed(d, from: 2.6, through: 3.9), .unknown(.stale))
        XCTAssertEqual(d.update(obs(4.0), tracks: []), .clear)
    }

    func testNotLevel() {
        let d = seen()
        feed(d, from: 0, through: 2.0)
        XCTAssertEqual(d.update(obs(2.1, level: false), tracks: []), .unknown(.notLevel))
    }

    /// The live watchdog going stale re-arms the hold, so Clear can't come straight back with the next frame.
    func testWatchdogStaleReArmsTheHold() {
        let d = seen()
        XCTAssertEqual(feed(d, from: 0, through: 2.0), .clear)
        d.noteExternalStale()
        XCTAssertEqual(d.update(obs(2.1), tracks: []), .unknown(.stale))
        XCTAssertEqual(feed(d, from: 2.2, through: 3.4), .unknown(.stale))
        XCTAssertEqual(d.update(obs(3.5), tracks: []), .clear)
    }

    /// Tilting right after a car was seen still reports the car, unchanged so nothing is spoken over the tone, then
    /// the tilt.
    /// Tilt loses the horizon, so it stops "no cars"; a car still in view is still reported.
    func testCarBeatsNotLevel() {
        guard case .approaching(.seconds) = Decider().update(obs(1.5, level: false), tracks: [approachingTrack]) else {
            return XCTFail("a car is reported while tilted")
        }
    }

    func testTooDark() {
        XCTAssertEqual(Decider().update(obs(0, luma: 0.05), tracks: []), .unknown(.tooDark))
    }

    func testTooBright() {
        XCTAssertEqual(Decider().update(obs(0, luma: 0.97), tracks: []), .unknown(.tooBright))
    }

    func testCovered() {
        XCTAssertEqual(Decider().update(obs(0, variance: 5), tracks: []), .unknown(.covered))
    }

    /// A hand over the lens is dark and flat: "camera covered", not "too dark".
    func testDarkAndFlatIsCovered() {
        XCTAssertEqual(Decider().update(obs(0, luma: 0.03, variance: 2), tracks: []), .unknown(.covered))
    }

    func testApproachingSeconds() {
        guard case .approaching(.seconds(let seconds)) = Decider().update(obs(1.5), tracks: [approachingTrack]) else {
            return XCTFail("expected a timed approach")
        }
        XCTAssertTrue((8...9).contains(seconds), "\(seconds)")
    }

    /// A track too new to measure has no distance yet: it may be close (after a rotation or an occlusion).
    func testNewTrackIsApproachingUnmeasured() {
        let new = makeTrack([(t: 1.5, h: 0.3)])
        XCTAssertEqual(Decider().update(obs(1.5), tracks: [new]), .approaching(.unmeasured))
    }

    /// Measured, plausibly arriving within the window, but the point estimate is beyond it: "far".
    func testMeasuredFarCarIsFar() throws {
        let far = try XCTUnwrap((1...200).lazy.map { seed in
            makeTrack(approachingHeights(tauAtEndSeconds: 30, heightAtEnd: 8 / 1920, noisePixels: 1.7, seed: UInt64(seed)))
        }.first { track in
            let e = track.estimate(atSeconds: 1.5)
            return (e.pointSeconds ?? .infinity) >= Config.approachWindowSeconds && (e.lowSeconds ?? .infinity) < Config.approachWindowSeconds
        })
        XCTAssertEqual(Decider().update(obs(1.5), tracks: [far]), .approaching(.far))
    }

    /// People are not tracked as cars, but a person filling the tile hides the road just like a parked car.
    func testPersonBlockingTileIsViewBlocked() {
        var o = obs(1.5)
        o.blockerBoxes = [CGRect(x: tile.minX, y: tile.minY, width: tile.width * 0.4, height: tile.height)]
        XCTAssertEqual(Decider().update(o, tracks: []), .unknown(.viewBlocked))
    }

    func testViewBlocked() {
        let blocking = parkedTrack(CGRect(x: tile.minX, y: tile.minY, width: tile.width * 0.4, height: tile.height))
        XCTAssertEqual(Decider().update(obs(1.5), tracks: [blocking]), .unknown(.viewBlocked))
        let partial = parkedTrack(CGRect(x: tile.minX, y: tile.minY, width: tile.width * 0.2, height: tile.height))
        XCTAssertEqual(feed(seen(), from: 1.5, through: 3.0, tracks: [partial]), .clear)
    }

    func testHoldKeepsPreviousState() {
        let d = seen()
        feed(d, from: 0, through: 1.4)
        guard case .approaching = d.update(obs(1.5), tracks: [approachingTrack]) else { return XCTFail("expected approach") }
        guard case .approaching = feed(d, from: 1.6, through: 2.9) else { return XCTFail("approach should be held") }
        XCTAssertEqual(d.update(obs(3.0), tracks: []), .clear)
    }

    /// Indoors, facing a wall or a hedge: nothing is detected, but that isn't "no cars" until a moving vehicle has
    /// shown there is a road; and the evidence runs out.
    func testNoCarsNeedsARoadSeen() {
        let d = Decider()
        XCTAssertEqual(feed(d, from: 0, through: 3.0), .unknown(.noRoadSeen))
        XCTAssertEqual(feed(d, from: 3.1, through: 4.3, tracks: [movingTrack]), .unknown(.noRoadSeen)) // clear hold
        XCTAssertEqual(feed(d, from: 4.4, through: 4.7, tracks: [movingTrack]), .clear)
        XCTAssertEqual(d.update(obs(4.8 + Config.roadEvidenceSeconds), tracks: []), .unknown(.noRoadSeen))
    }

    /// A big parked car beside the tile must not block Clear forever.
    func testNearParkedCarAllowsClear() {
        let parked = parkedTrack(CGRect(x: 0, y: 0.4, width: 0.2, height: 0.15))
        XCTAssertEqual(feed(seen(), from: 1.5, through: 3.0, tracks: [parked]), .clear)
    }

    /// The front camera seeing the user's face: the phone is held like a phone, not edge-on.
    func testFaceFillingTheFrontCameraIsFacingUser() {
        let d = seen()
        XCTAssertEqual(d.update(obs(1.5, faces: [CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.3)]), tracks: []),
                       .unknown(.facingUser))
        XCTAssertNil(d.roadSeenSeconds)
    }

    /// The phone turned off the heading it had when a car last came along the road.
    func testHeadingDriftIsMisaimed() {
        let d = Decider()
        _ = d.update(obs(0, heading: 90), tracks: [movingTrack])
        XCTAssertNotEqual(d.update(obs(0.1, heading: 100), tracks: []), .unknown(.misaimed))
        XCTAssertEqual(d.headingErrorDegrees ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(d.update(obs(0.2, heading: 140), tracks: []), .unknown(.misaimed))
    }

    /// Cars sliding across the picture without growing: the camera looks across the road.
    func testCrossingTrafficIsMisaimed() {
        var crossing = makeTrack(parkedHeights(height: 0.1, noisePixels: 0, seed: 1))
        crossing.directionBoxes = (0...10).map { i in
            let t = Double(i) / 10
            return (t, CGRect(x: 0.1 + 0.4 * t, y: 0.45, width: 0.2, height: 0.1))
        }
        let d = seen()
        XCTAssertEqual(d.update(obs(1.5), tracks: [crossing]), .unknown(.misaimed))
        XCTAssertNil(d.roadSeenSeconds)
    }

    /// No calibrated compass (or none at all) gives no heading; that alone never reads as misaimed.
    func testNoHeadingNeverMisaimedByCompass() {
        let d = Decider()
        _ = d.update(obs(0, heading: 90), tracks: [movingTrack])
        XCTAssertNotEqual(d.update(obs(0.1, heading: nil), tracks: []), .unknown(.misaimed))
        XCTAssertNil(d.headingErrorDegrees)
    }

    /// Curb only: while the phone moves, box growth says nothing about cars.
    func testMovingIsUnknown() {
        XCTAssertEqual(seen().update(obs(0, still: false), tracks: []), .unknown(.moving))
    }

    func testMovingKeepsACarJustSeen() {
        let d = Decider()
        let car = d.update(obs(1.5), tracks: [approachingTrack])
        XCTAssertEqual(d.update(obs(1.6, still: false), tracks: []), car)
        XCTAssertEqual(d.update(obs(2.6, still: false), tracks: []), .unknown(.moving))
    }

    func testMovingBeatsNotLevel() {
        XCTAssertEqual(Decider().update(obs(0, level: false, still: false), tracks: []), .unknown(.moving))
    }

    /// Replayed footage never says "Hold still".
    func testReplayFramesAreStill() {
        XCTAssertTrue(makeFrame(makeLumaBuffer(width: 8, height: 8) { _, _ in 128 }).isStill)
    }

    /// Growing over the last 1.5 s (noise) but shrinking for sure over the 4 s window: a car that already passed.
    func testCarDrivingAwayIsIgnored() {
        var leaving = trackWithDirection(heightAt: { 0.2 * (1 - 0.1 * $0) })
        leaving.heights = approachingHeights(tauAtEndSeconds: 8.5, heightAtEnd: 0.12)
        XCTAssertEqual(leaving.travel, .away)
        if case .approaching = seen().update(obs(4), tracks: [leaving]) { XCTFail("a leaving car is not coming") }
    }

    /// Coming along the road (growing), its center drifting `drift` of the picture width over the 4 s window.
    private func comingCar(id: Int, drift: Double) -> Track {
        trackWithDirection(heightAt: { 0.05 * (1 + 0.2 * $0) }, xAt: { 0.5 + drift * $0 / 4 }, id: id)
    }

    /// Approaching cars drift toward the street's side, the left half of both pictures; two drifting right in a row
    /// mean the phone is held the other way round.
    func testTwoCarsDriftingTheWrongWayIsTurnedAround() {
        let d = Decider(checksTurnAround: true)
        d.roadSeenSeconds = 0
        _ = d.update(obs(4), tracks: [comingCar(id: 1, drift: 0.1)])
        XCTAssertEqual(feed(d, from: 4.1, through: 6, tracks: [comingCar(id: 2, drift: 0.1)]), .unknown(.turnedAround))
    }

    func testOneRightCarClearsTurnedAround() {
        let d = Decider(checksTurnAround: true)
        d.roadSeenSeconds = 0
        _ = d.update(obs(4), tracks: [comingCar(id: 1, drift: 0.1), comingCar(id: 2, drift: 0.1)])
        _ = d.update(obs(4.1), tracks: [comingCar(id: 3, drift: -0.1)])
        XCTAssertNotEqual(feed(d, from: 4.2, through: 6), .unknown(.turnedAround))
    }

    /// Replayed footage was filmed any way round, so it never says "Turn the phone around".
    func testReplayNeverTurnedAround() {
        let d = seen()
        XCTAssertNotEqual(feed(d, from: 4, through: 6, tracks: [comingCar(id: 1, drift: 0.1), comingCar(id: 2, drift: 0.1)]),
                          .unknown(.turnedAround))
    }

    /// The road is a line, not a direction: obeying "Turn the phone around" turns the camera axis 180° and must not
    /// read as misaimed (review I2), or the two instructions would send the user back and forth.
    func testTurningThePhoneAroundIsNotMisaimed() {
        let d = Decider(checksTurnAround: true)
        d.roadSeenSeconds = 0
        _ = d.update(obs(4, heading: 270), tracks: [comingCar(id: 1, drift: 0.1), comingCar(id: 2, drift: 0.1)])
        XCTAssertNotEqual(d.update(obs(4.1, heading: 90), tracks: []), .unknown(.misaimed))
        XCTAssertEqual(d.headingErrorDegrees ?? -1, 0, accuracy: 1e-9)
    }

    /// A parked car sliding sideways (the hand turning) is no evidence of which way the street lies.
    func testDriftOfANonApproachingCarDoesNotCount() {
        let d = Decider(checksTurnAround: true)
        d.roadSeenSeconds = 0
        let parked = { (id: Int) in trackWithDirection(heightAt: { _ in 0.1 }, xAt: { 0.5 + 0.1 * $0 / 4 }, id: id) }
        XCTAssertNotEqual(feed(d, from: 4, through: 6, tracks: [parked(1), parked(2)]), .unknown(.turnedAround))
    }

    /// Seen from behind silences a car only once the owner turns it on (after the curb field test).
    func testRearCarCountsUntilEnabled() {
        var t = makeTrack(approachingHeights(tauAtEndSeconds: 8.5, heightAtEnd: 0.02))
        t.rearFrames = 3
        XCTAssertTrue(countsAsComing(t, suppressesRear: false))
        XCTAssertFalse(countsAsComing(t, suppressesRear: true))
    }
}

/// The live watchdog runs on main from host arrival times, so a hung pipeline or an ended replay still goes stale.
final class WatchdogTests: XCTestCase {
    func testSilentSideGoesStale() {
        XCTAssertEqual(staleSides(lastUpdateSeconds: [.left: 10, .right: 10.2], nowSeconds: 10.31), [.left])
        XCTAssertEqual(staleSides(lastUpdateSeconds: [.left: 10], nowSeconds: 10.29), [])
    }

    /// A silent side says why when the reason is known (permission, heat, camera in use).
    func testSilentSideReadsItsFault() {
        XCTAssertEqual(silentSideState(fault: nil), .unknown(.stale))
        XCTAssertEqual(silentSideState(fault: .overheated), .unknown(.overheated))
        XCTAssertEqual(interruptionFault(.videoDeviceNotAvailableDueToSystemPressure), .overheated)
        XCTAssertEqual(interruptionFault(.videoDeviceInUseByAnotherClient), .interrupted)
        XCTAssertEqual(interruptionFault(nil), .interrupted)
    }
}
