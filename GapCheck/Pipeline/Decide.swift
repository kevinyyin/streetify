import CoreGraphics

enum Side {
    case left, right
}

enum UnknownReason: Equatable {
    case stale, notLevel, tooDark, tooBright, covered, viewBlocked
    /// Camera faults the user can act on; AppModel sets them, Decide never does.
    case noPermission, unsupported, interrupted, overheated
    /// No moving vehicle seen lately, so an empty picture says nothing about the road.
    case noRoadSeen
    /// The front camera sees the user's face: the screen faces them, not down the road.
    case facingUser
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
    /// Faces the front camera sees, Vision-normalized; always empty for the back camera.
    var faceBoxes: [CGRect] = []
}

/// The ordered rules for one direction. Starts Unknown; every failure ends Unknown, never Clear.
final class Decider {
    private(set) var state: DirectionState = .unknown(.stale)
    /// Frame time a moving vehicle last showed this camera sees a road. Internal so tests can start with a road seen.
    var roadSeenSeconds: Double?
    private var lastFrameSeconds: Double?
    private var lastFiredSeconds = -Double.infinity
    private var lastApproachSeconds: Double?

    /// Rule 1. Live: the watchdog calls this on host time. Replay: `update` calls it per frame to catch gaps.
    @discardableResult
    func checkStale(nowSeconds: Double) -> DirectionState {
        if let last = lastFrameSeconds, nowSeconds - last > Config.staleFrameTimeoutSeconds {
            state = .unknown(.stale)
            lastFiredSeconds = nowSeconds
        }
        return state
    }

    /// The live watchdog (host clock) found this side silent. Re-arms the hold on frame time, so the next Clear
    /// still waits `Config.clearHoldSeconds` instead of coming back with the next frame.
    func noteExternalStale() {
        state = .unknown(.stale)
        if let last = lastFrameSeconds { lastFiredSeconds = last }
    }

    /// Rules 2 to 7 for a frame whose detection succeeded.
    func update(_ o: FrameObservation, tracks: [Track]) -> DirectionState {
        let t = o.timestampSeconds
        if lastFrameSeconds == nil { lastFiredSeconds = t } // having had no frames counts as rule 1 firing
        checkStale(nowSeconds: t)
        lastFrameSeconds = t
        // Road evidence: a vehicle growing or shrinking travels along the camera axis, so this camera sees a road.
        if o.isLevel, tracks.contains(where: { $0.travel != .unclear }) { roadSeenSeconds = t }
        if let seen = roadSeenSeconds, t - seen > Config.roadEvidenceSeconds { roadSeenSeconds = nil }
        if let fired = firstFiringRule(o, tracks) {
            state = fired
            lastFiredSeconds = t
        } else if t - lastFiredSeconds >= Config.clearHoldSeconds {
            state = .clear
        }
        return state
    }

    private func firstFiringRule(_ o: FrameObservation, _ tracks: [Track]) -> DirectionState? {
        let t = o.timestampSeconds
        if !o.isLevel {
            // Tilting doesn't make a car that was just seen go away. It keeps the car as last reported, so the tilt
            // itself is no news: nothing is spoken over the tone.
            if let seen = lastApproachSeconds, t - seen <= Config.tiltCarMemorySeconds {
                if case .approaching = state { return state }
                return .approaching(.unmeasured)
            }
            return .unknown(.notLevel)
        }
        if let reason = qualityProblem(o.quality) { return .unknown(reason) }

        let approaching = tracks.map { $0.estimate(atSeconds: t) }
            .filter { $0.isTooNew || ($0.lowSeconds ?? .infinity) < Config.approachWindowSeconds }
        if !approaching.isEmpty {
            lastApproachSeconds = t
            if let soonest = approaching.compactMap(\.pointSeconds).filter({ $0 < Config.approachWindowSeconds }).min() {
                return .approaching(.seconds(Int(soonest.rounded())))
            }
            return .approaching(approaching.contains(where: \.isTooNew) ? .unmeasured : .far)
        }

        if o.faceBoxes.reduce(0.0, { $0 + $1.width * $1.height }) >= Config.faceMinAreaFraction {
            roadSeenSeconds = nil
            return .unknown(.facingUser)
        }

        // Every remaining track is stationary or leaving; people hide the road too.
        let coveredArea = (tracks.map(\.box) + o.blockerBoxes).reduce(0.0) { sum, box in
            let overlap = box.intersection(o.tile)
            return overlap.isNull ? sum : sum + overlap.width * overlap.height
        }
        if coveredArea / (o.tile.width * o.tile.height) > Config.blockedFraction { return .unknown(.viewBlocked) }
        // Clear means "road seen and empty", not "nothing detected" (a wall, a hedge, indoors).
        if roadSeenSeconds == nil { return .unknown(.noRoadSeen) }
        return nil
    }
}

/// Rule 3. A dark, flat picture is a covered lens, not night (a night street still has lights in it).
func qualityProblem(_ q: ImageQuality) -> UnknownReason? {
    let isFlat = q.laplacianVariance < Config.minLaplacianVariance
    if isFlat && q.meanLuma <= Config.maxMeanLuma { return .covered }
    if q.meanLuma < Config.minMeanLuma { return .tooDark }
    if q.meanLuma > Config.maxMeanLuma { return .tooBright }
    return nil
}
