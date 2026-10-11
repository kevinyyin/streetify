import XCTest
@testable import GapCheck

final class TrackTests: XCTestCase {
    func testTimeToArrivalNoiseless() {
        let e = makeTrack(approachingHeights(tauAtEndSeconds: 8.5, heightAtEnd: 0.02)).estimate(atSeconds: 1.5)
        XCTAssertFalse(e.isTooNew)
        XCTAssertEqual(e.pointSeconds ?? -1, 8.5, accuracy: 0.3)
    }

    func testTooNewIsFlagged() {
        let e = makeTrack(approachingHeights(tauAtEndSeconds: 8.5, heightAtEnd: 0.02, durationSeconds: 1.0)).estimate(atSeconds: 1.0)
        XCTAssertTrue(e.isTooNew)
    }

    /// Invariant 3: a far car whose growth is within the noise must still read as approaching.
    func testFarNoisyCarStaysApproaching() {
        let approaching = (1...100).filter { seed in
            let e = makeTrack(approachingHeights(tauAtEndSeconds: 15, heightAtEnd: 13.5 / 1920, noisePixels: 1.7, seed: UInt64(seed)))
                .estimate(atSeconds: 1.5)
            return (e.lowSeconds ?? .infinity) < Config.approachWindowSeconds
        }.count
        XCTAssertGreaterThanOrEqual(approaching, 95)
    }

    func testNearParkedCarIsNotApproaching() {
        for seed in 1...100 {
            let e = makeTrack(parkedHeights(height: 192 / 1920, noisePixels: 1.7, seed: UInt64(seed))).estimate(atSeconds: 1.5)
            XCTAssertGreaterThanOrEqual(e.lowSeconds ?? .infinity, Config.approachWindowSeconds, "seed \(seed)")
        }
    }

    /// Shrinking slowly over the 4 s direction window is driving away (screen only); a parked car's jitter is neither
    /// way, and it is at a standstill.
    func testSlowlyShrinkingCarIsDrivingAway() {
        XCTAssertEqual(trackWithDirection(heightAt: { 0.08 * (1 - 0.06 * $0) }).travel, .away)
        XCTAssertEqual(trackWithDirection(heightAt: { 0.05 * (1 + 0.2 * $0) }).travel, .toward)
        for seed in 1...100 {
            var parked = makeTrack(parkedHeights(height: 192 / 1920, noisePixels: 1.7, seed: UInt64(seed)))
            parked.directionBoxes = parked.heights.map { ($0.t, CGRect(x: 0.4, y: 0.4, width: 2 * $0.h, height: $0.h)) }
            XCTAssertEqual(parked.travel, .unclear, "seed \(seed)")
            XCTAssertTrue(parked.isStill, "seed \(seed)")
        }
    }

    /// A car crossing in front keeps its height but is not at a standstill.
    func testCrossingCarIsNotStill() {
        var crossing = makeTrack(parkedHeights(height: 0.1, noisePixels: 0, seed: 1))
        crossing.directionBoxes = (0...20).map { i in
            let t = Double(i) / Config.processFps
            return (t, CGRect(x: 0.2 + 0.2 * t, y: 0.4, width: 0.2, height: 0.1))
        }
        XCTAssertFalse(crossing.isStill)
    }

    func testIoUMatchKeepsId() {
        let tracker = Tracker()
        let a = tracker.update([car(CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.05))], atSeconds: 0, orientation: .up)
        let b = tracker.update([car(CGRect(x: 0.505, y: 0.5, width: 0.1, height: 0.05))], atSeconds: 0.1, orientation: .up)
        XCTAssertEqual(b.map(\.id), a.map(\.id))
    }

    func testNearestCenterFallback() {
        let box = CGRect(x: 0.5, y: 0.5, width: 0.02, height: 0.02)
        let near = Tracker()
        let a = near.update([car(box)], atSeconds: 0, orientation: .up)
        XCTAssertEqual(near.update([car(box.offsetBy(dx: 0.016, dy: 0))], atSeconds: 0.1, orientation: .up).map(\.id), a.map(\.id))

        let far = Tracker()
        let c = far.update([car(box)], atSeconds: 0, orientation: .up)
        let d = far.update([car(box.offsetBy(dx: 0.024, dy: 0))], atSeconds: 0.1, orientation: .up)
        XCTAssertFalse(d.contains { $0.id == c[0].id && $0.lastSeenSeconds == 0.1 })
    }

    func testBriefMissKeepsTrack() {
        let tracker = Tracker()
        _ = tracker.update([car(CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.05))], atSeconds: 0, orientation: .up)
        XCTAssertEqual(tracker.update([], atSeconds: 0.3, orientation: .up).count, 1)
        XCTAssertEqual(tracker.update([], atSeconds: 0.6, orientation: .up).count, 0)
    }

    func testOrientationChangeResetsTracks() {
        let tracker = Tracker()
        let box = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.05)
        let a = tracker.update([car(box)], atSeconds: 0, orientation: .up)
        let b = tracker.update([car(box)], atSeconds: 0.1, orientation: .right)
        XCTAssertEqual(b.count, 1)
        XCTAssertNotEqual(b[0].id, a[0].id)
        XCTAssertTrue(b[0].estimate(atSeconds: 0.1).isTooNew)
    }

    /// Sliding across the picture without growing reads as crossing; coming along the road (growing) does not.
    func testCrossingView() {
        var crossing = makeTrack(parkedHeights(height: 0.1, noisePixels: 0, seed: 1))
        crossing.directionBoxes = (0...10).map { i in
            let t = Double(i) / 10
            return (t, CGRect(x: 0.1 + 0.4 * t, y: 0.45, width: 0.2, height: 0.1))
        }
        XCTAssertTrue(crossing.isCrossingView)
        XCTAssertFalse(trackWithDirection(heightAt: { 0.05 * (1 + 0.2 * $0) }).isCrossingView)
    }
}
