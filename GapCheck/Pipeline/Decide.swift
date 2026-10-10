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
}

/// What is coming; speech names it.
enum Mover: Int, Comparable {
    case car, bike, person
    static func < (a: Mover, b: Mover) -> Bool { a.rawValue < b.rawValue }
}

/// The mover a detector label stands for; nil for labels that are neither vehicles nor people.
func labelMover(_ label: String) -> Mover? {
    if Config.bikeLabels.contains(label) { return .bike }
    if Config.vehicleLabels.contains(label) { return .car }
    if Config.personLabels.contains(label) { return .person }
    return nil
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
    case approaching(Arrival, Mover = .car)
    case unknown(UnknownReason)
}

/// What Decide needs from one frame besides its tracks.
struct FrameObservation {
    let timestampSeconds: Double
    let isLevel: Bool
    let quality: ImageQuality
    let tile: CGRect
    /// Compass heading of the camera axis; nil without a calibrated compass, and in replay.
    var headingDegrees: Double? = nil
    /// Faces the front camera sees, Vision-normalized; always empty for the back camera.
    var faceBoxes: [CGRect] = []
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
    private var lockedHeadingDegrees: Double?
    private var lastCrossingSeconds = -Double.infinity
    private var lastApproach: (seconds: Double, mover: Mover)?

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

    /// Rules 2 to 9 for a frame whose detection succeeded.
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
        if tracks.contains(where: { $0.isCrossingView }) {
            lastCrossingSeconds = t
            roadSeenSeconds = nil // it was looking across the road, not along it
        } else if o.isLevel, tracks.contains(where: { $0.mover != .person && $0.travel != .unclear }) {
            // A vehicle growing or shrinking travels along the camera axis: this is the road, and this the heading.
            roadSeenSeconds = t
            if let heading = o.headingDegrees { lockedHeadingDegrees = heading }
        }
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

    private func firstFiringRule(_ o: FrameObservation, _ tracks: [Track]) -> DirectionState? {
        let t = o.timestampSeconds
        if !o.isLevel {
            // Tilting doesn't make a car that was just seen go away.
            if let car = lastApproach, t - car.seconds <= Config.tiltCarMemorySeconds { return .approaching(.unmeasured, car.mover) }
            return .unknown(.notLevel)
        }
        if let reason = qualityProblem(o.quality) { return .unknown(reason) }

        if let coming = soonestApproach(tracks, atSeconds: t) {
            lastApproach = (t, coming.mover)
            return .approaching(coming.arrival, coming.mover)
        }

        if o.faceBoxes.reduce(0.0, { $0 + $1.width * $1.height }) >= Config.faceMinAreaFraction {
            roadSeenSeconds = nil
            return .unknown(.facingUser)
        }
        if (headingErrorDegrees ?? 0) > Config.headingToleranceDegrees || t - lastCrossingSeconds <= Config.misaimMemorySeconds {
            return .unknown(.misaimed)
        }

        // Every remaining track is stationary, leaving, or a person not measured coming; they hide the road.
        let coveredArea = tracks.map(\.box).reduce(0.0) { sum, box in
            let overlap = box.intersection(o.tile)
            return overlap.isNull ? sum : sum + overlap.width * overlap.height
        }
        if coveredArea / (o.tile.width * o.tile.height) > Config.blockedFraction { return .unknown(.viewBlocked) }
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
    if isPartlyCovered(q) { return .covered }
    return nil
}

/// Rule 4. Vehicles count while too new to measure (they may be close); people only once measured coming, so
/// everyone stepping into view isn't a warning. The soonest timed one wins; otherwise "unmeasured" if any is too new.
func soonestApproach(_ tracks: [Track], atSeconds t: Double) -> (arrival: Arrival, mover: Mover)? {
    var timed: [(seconds: Double, mover: Mover)] = []
    var untimed: [(isTooNew: Bool, mover: Mover)] = []
    for track in tracks {
        let e = track.estimate(atSeconds: t)
        let isSoon = (e.lowSeconds ?? .infinity) < Config.approachWindowSeconds
        let counts = track.mover == .person ? !e.isTooNew && isSoon : e.isTooNew || isSoon
        guard counts else { continue }
        if let seconds = e.pointSeconds, seconds < Config.approachWindowSeconds {
            timed.append((seconds, track.mover))
        } else {
            untimed.append((e.isTooNew, track.mover))
        }
    }
    if let soonest = timed.min(by: { $0.seconds < $1.seconds }) {
        return (.seconds(Int(soonest.seconds.rounded())), soonest.mover)
    }
    guard let mover = untimed.map({ $0.mover }).min() else { return nil }
    return (untimed.contains(where: { $0.isTooNew }) ? .unmeasured : .far, mover)
}
