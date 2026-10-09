import CoreGraphics

enum Side {
    case left, right
}

enum UnknownReason: Equatable {
    case stale, notLevel, tooDark, tooBright, covered, viewBlocked
}

/// How soon an approaching car arrives, as far as can be told.
enum Arrival: Equatable {
    case seconds(Int)
    /// Measured, but its best estimate is beyond the approach window.
    case far
    /// Too new to measure: no distance yet, and it may be close.
    case unmeasured
}

enum DirectionState: Equatable {
    case clear
    case approaching(Arrival)
    case unknown(UnknownReason)
}

/// What Decide needs from one frame besides its tracks.
struct FrameObservation {
    let timestampSeconds: Double
    let isLevel: Bool
    let quality: ImageQuality
    let tile: CGRect
    /// Non-vehicles (people) that hide the road; they count toward rule 5 but are never tracked as cars.
    var blockerBoxes: [CGRect] = []
}

/// The ordered rules for one direction. Starts Unknown; every failure ends Unknown, never Clear.
final class Decider {
    private(set) var state: DirectionState = .unknown(.stale)
    private var lastFrameSeconds: Double?
    private var lastFiredSeconds = -Double.infinity

    /// Rule 1. Live: the watchdog calls this on host time. Replay: `update` calls it per frame to catch gaps.
    @discardableResult
    func checkStale(nowSeconds: Double) -> DirectionState {
        if let last = lastFrameSeconds, nowSeconds - last > Config.staleFrameTimeoutSeconds {
            state = .unknown(.stale)
            lastFiredSeconds = nowSeconds
        }
        return state
    }

    /// Rules 2 to 6 for a frame whose detection succeeded.
    func update(_ o: FrameObservation, tracks: [Track]) -> DirectionState {
        let t = o.timestampSeconds
        if lastFrameSeconds == nil { lastFiredSeconds = t } // having had no frames counts as rule 1 firing
        checkStale(nowSeconds: t)
        lastFrameSeconds = t
        if let fired = firstFiringRule(o, tracks) {
            state = fired
            lastFiredSeconds = t
        } else if t - lastFiredSeconds >= Config.clearHoldSeconds {
            state = .clear
        }
        return state
    }

    private func firstFiringRule(_ o: FrameObservation, _ tracks: [Track]) -> DirectionState? {
        if !o.isLevel { return .unknown(.notLevel) }
        if o.quality.meanLuma < Config.minMeanLuma { return .unknown(.tooDark) }
        if o.quality.meanLuma > Config.maxMeanLuma { return .unknown(.tooBright) }
        if o.quality.laplacianVariance < Config.minLaplacianVariance { return .unknown(.covered) }

        let approaching = tracks.map { $0.estimate(atSeconds: o.timestampSeconds) }
            .filter { $0.isTooNew || ($0.lowSeconds ?? .infinity) < Config.approachWindowSeconds }
        if !approaching.isEmpty {
            if let soonest = approaching.compactMap(\.pointSeconds).filter({ $0 < Config.approachWindowSeconds }).min() {
                return .approaching(.seconds(Int(soonest.rounded())))
            }
            return .approaching(approaching.contains(where: \.isTooNew) ? .unmeasured : .far)
        }

        // Every remaining track is stationary or leaving; people hide the road too.
        let coveredArea = (tracks.map(\.box) + o.blockerBoxes).reduce(0.0) { sum, box in
            let overlap = box.intersection(o.tile)
            return overlap.isNull ? sum : sum + overlap.width * overlap.height
        }
        if coveredArea / (o.tile.width * o.tile.height) > Config.blockedFraction { return .unknown(.viewBlocked) }
        return nil
    }
}
