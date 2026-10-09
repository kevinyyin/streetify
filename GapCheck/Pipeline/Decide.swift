import CoreGraphics

enum Side {
    case left, right
}

enum UnknownReason: Equatable {
    case stale, notLevel, tooDark, tooBright, covered, viewBlocked
}

enum DirectionState: Equatable {
    case clear
    /// nil seconds = "far": seen, but no usable time yet.
    case approaching(seconds: Int?)
    case unknown(UnknownReason)
}

/// What Decide needs from one frame besides its tracks.
struct FrameObservation {
    let timestampSeconds: Double
    let isLevel: Bool
    let quality: ImageQuality
    let tile: CGRect
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
            let soonest = approaching.compactMap(\.pointSeconds).filter { $0 < Config.approachWindowSeconds }.min()
            return .approaching(seconds: soonest.map { Int($0.rounded()) })
        }

        // Every remaining track is stationary or leaving.
        let coveredArea = tracks.reduce(0.0) { sum, track in
            let overlap = track.box.intersection(o.tile)
            return overlap.isNull ? sum : sum + overlap.width * overlap.height
        }
        if coveredArea / (o.tile.width * o.tile.height) > Config.blockedFraction { return .unknown(.viewBlocked) }
        return nil
    }
}
