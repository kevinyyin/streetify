import XCTest
@testable import GapCheck

final class DecideTests: XCTestCase {
    private let tile = tileRect(orientedWidthPixels: 1080, orientedHeightPixels: 1920)

    private func obs(_ t: Double, level: Bool = true, luma: Double = 0.5, variance: Double = 100) -> FrameObservation {
        FrameObservation(timestampSeconds: t, isLevel: level,
                    quality: ImageQuality(meanLuma: luma, laplacianVariance: variance), tile: tile)
    }

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
        let d = Decider()
        XCTAssertEqual(feed(d, from: 0, through: 1.4), .unknown(.stale))
        XCTAssertEqual(d.update(obs(1.5), tracks: []), .clear)
    }

    /// Invariant 2: frames stop (or every detection throws, so Decide never updates) → Unknown, never Clear.
    func testNoFramesAfterClearGoesStale() {
        let d = Decider()
        XCTAssertEqual(feed(d, from: 0, through: 2.0), .clear)
        XCTAssertEqual(d.checkStale(nowSeconds: 2.29), .clear)
        XCTAssertEqual(d.checkStale(nowSeconds: 2.31), .unknown(.stale))
    }

    func testReplayGapIsStale() {
        let d = Decider()
        feed(d, from: 0, through: 2.0)
        XCTAssertEqual(d.update(obs(2.5), tracks: []), .unknown(.stale))
        XCTAssertEqual(feed(d, from: 2.6, through: 3.9), .unknown(.stale))
        XCTAssertEqual(d.update(obs(4.0), tracks: []), .clear)
    }

    func testNotLevel() {
        let d = Decider()
        feed(d, from: 0, through: 2.0)
        XCTAssertEqual(d.update(obs(2.1, level: false), tracks: []), .unknown(.notLevel))
    }

    func testNotLevelBeatsApproaching() {
        XCTAssertEqual(Decider().update(obs(1.5, level: false), tracks: [approachingTrack]), .unknown(.notLevel))
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
        XCTAssertEqual(feed(Decider(), from: 1.5, through: 3.0, tracks: [partial]), .clear)
    }

    func testHoldKeepsPreviousState() {
        let d = Decider()
        feed(d, from: 0, through: 1.4)
        guard case .approaching = d.update(obs(1.5), tracks: [approachingTrack]) else { return XCTFail("expected approach") }
        guard case .approaching = feed(d, from: 1.6, through: 2.9) else { return XCTFail("approach should be held") }
        XCTAssertEqual(d.update(obs(3.0), tracks: []), .clear)
    }

    /// A big parked car beside the tile must not block Clear forever.
    func testNearParkedCarAllowsClear() {
        let parked = parkedTrack(CGRect(x: 0, y: 0.4, width: 0.2, height: 0.15))
        XCTAssertEqual(feed(Decider(), from: 1.5, through: 3.0, tracks: [parked]), .clear)
    }
}

/// The live watchdog runs on main from host arrival times, so a hung pipeline or an ended replay still goes stale.
final class WatchdogTests: XCTestCase {
    func testSilentSideGoesStale() {
        XCTAssertEqual(staleSides(lastUpdateSeconds: [.left: 10, .right: 10.2], nowSeconds: 10.31), [.left])
        XCTAssertEqual(staleSides(lastUpdateSeconds: [.left: 10], nowSeconds: 10.29), [])
    }
}
