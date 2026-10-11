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
    /// The phone turned off the street heading (compass), or cars cross the picture instead of coming along it.
    case misaimed
    /// Curb only: the phone is moving (the user walks), so box growth says nothing about cars.
    case moving
    /// Approaching cars drift away from the street's side of the picture: the screen faces right, not left, so every
    /// "Left" and "Right" would be swapped.
    case turnedAround
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
    /// Compass heading of the camera axis; nil without a calibrated compass, and in replay.
    var headingDegrees: Double? = nil
    /// Held still; replay frames are still.
    var isStill = true
}

/// The ordered rules for one direction. Starts Unknown; every failure ends Unknown, never Clear.
final class Decider {
    private(set) var state: DirectionState = .unknown(.stale)
    /// How far the compass is from the locked street heading, for the tone; nil when unlocked or without a compass.
    private(set) var headingErrorDegrees: Double?
    /// Frame time a moving vehicle last showed this camera sees a road. Internal so tests can start with a road seen.
    var roadSeenSeconds: Double?
    private var lastFrameSeconds: Double?
    private var lastFiredSeconds = -Double.infinity
    private var lastApproachSeconds: Double?
    private var lockedHeadingDegrees: Double?
    private var lastCrossingSeconds = -Double.infinity
    /// Live cameras only: replayed footage was filmed any way round.
    private let checksTurnAround: Bool
    /// Approaching cars already judged for the turn-around check, and whether the last few drifted the right way.
    private var judgedTrackIds = Set<Int>()
    private var recentDriftsRight: [Bool] = []

    init(checksTurnAround: Bool = false) {
        self.checksTurnAround = checksTurnAround
    }

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
        noteAim(o, tracks)
        if let fired = firstFiringRule(o, tracks) {
            state = fired
            lastFiredSeconds = t
        } else if t - lastFiredSeconds >= Config.clearHoldSeconds {
            state = .clear
        }
        return state
    }

    /// Road evidence, the street heading and crossing traffic, before the rules read them.
    private func noteAim(_ o: FrameObservation, _ tracks: [Track]) {
        let t = o.timestampSeconds
        let canJudgeAim = o.isLevel && o.isStill // turning or walking slides and grows boxes too
        if canJudgeAim, tracks.contains(where: \.isCrossingView) {
            lastCrossingSeconds = t
            roadSeenSeconds = nil // it was looking across the road, not along it
        } else if canJudgeAim, tracks.contains(where: { $0.travel != .unclear }) {
            // A vehicle growing or shrinking travels along the camera axis: this is the road, and this the heading.
            roadSeenSeconds = t
            if let heading = o.headingDegrees { lockedHeadingDegrees = heading }
        }
        if checksTurnAround, canJudgeAim { noteDrift(tracks) }
        if let seen = roadSeenSeconds, t - seen > Config.roadEvidenceSeconds {
            roadSeenSeconds = nil
            lockedHeadingDegrees = nil // maybe a new crossing; the next car there locks again
        }
        if let lock = lockedHeadingDegrees, let heading = o.headingDegrees {
            headingErrorDegrees = angleDifferenceDegrees(heading, lock)
        } else {
            headingErrorDegrees = nil
        }
    }

    /// Turn-around evidence, once per approaching car: with the screen facing left, the street lies in the left half
    /// of both pictures (front mirrored by its EXIF orientation), so an approaching car drifts toward smaller x.
    private func noteDrift(_ tracks: [Track]) {
        judgedTrackIds.formIntersection(tracks.map(\.id))
        for track in tracks where track.travel == .toward && !judgedTrackIds.contains(track.id) {
            guard let drift = track.driftFraction, abs(drift) >= Config.turnedAroundMinDriftFraction else { continue }
            judgedTrackIds.insert(track.id)
            recentDriftsRight = Array((recentDriftsRight + [drift < 0]).suffix(Config.turnedAroundMinCars))
        }
    }

    private func firstFiringRule(_ o: FrameObservation, _ tracks: [Track]) -> DirectionState? {
        let t = o.timestampSeconds
        if !o.isStill {
            // Curb only (owner, 2026-10-10): walking makes every box grow as if a car were coming.
            return carJustSeen(atSeconds: t) ?? .unknown(.moving)
        }
        if let reason = qualityProblem(o.quality) { return .unknown(reason) }

        let approaching = tracks.filter { countsAsComing($0) }.map { $0.estimate(atSeconds: t) }
            .filter { $0.isTooNew || ($0.lowSeconds ?? .infinity) < Config.approachWindowSeconds }
        if !approaching.isEmpty {
            lastApproachSeconds = t
            if let soonest = approaching.compactMap(\.pointSeconds).filter({ $0 < Config.approachWindowSeconds }).min() {
                return .approaching(.seconds(Int(soonest.rounded())))
            }
            return .approaching(approaching.contains(where: \.isTooNew) ? .unmeasured : .far)
        }
        // Tilt loses the horizon (far cars), so it stops "no cars"; cars still in view were reported above.
        if !o.isLevel { return .unknown(.notLevel) }

        if o.faceBoxes.reduce(0.0, { $0 + $1.width * $1.height }) >= Config.faceMinAreaFraction {
            roadSeenSeconds = nil
            return .unknown(.facingUser)
        }
        if (headingErrorDegrees ?? 0) > Config.headingToleranceDegrees || t - lastCrossingSeconds <= Config.misaimMemorySeconds {
            return .unknown(.misaimed)
        }
        if checksTurnAround, recentDriftsRight.count == Config.turnedAroundMinCars, !recentDriftsRight.contains(true) {
            return .unknown(.turnedAround)
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

extension Decider {
    /// While the phone moves, a car reported within `Config.carMemorySeconds` stays as last said.
    fileprivate func carJustSeen(atSeconds t: Double) -> DirectionState? {
        guard let seen = lastApproachSeconds, t - seen <= Config.carMemorySeconds else { return nil }
        if case .approaching = state { return state }
        return .approaching(.unmeasured)
    }
}

/// Rule 4 only counts cars that may be coming: one shrinking for sure over the direction window has already passed
/// (approved by the owner 2026-10-10, invariant 3). Too-new tracks still count; they may be close. Seen from behind
/// (the front/rear model) counts too until the owner turns `Config.directionModelSuppressesRearCars` on.
func countsAsComing(_ track: Track, suppressesRear: Bool = Config.directionModelSuppressesRearCars) -> Bool {
    track.travel != .away && !(suppressesRear && track.isSeenFromBehind)
}

/// Rule 3. A dark, flat picture is a covered lens, not night (a night street still has lights in it).
func qualityProblem(_ q: ImageQuality) -> UnknownReason? {
    let isFlat = q.laplacianVariance < Config.minLaplacianVariance
    if isFlat && q.meanLuma <= Config.maxMeanLuma { return .covered }
    if q.meanLuma < Config.minMeanLuma { return .tooDark }
    if q.meanLuma > Config.maxMeanLuma { return .tooBright }
    return nil
}
