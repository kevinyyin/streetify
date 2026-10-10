import CoreGraphics
import ImageIO

/// Which way a car is going, for the screen only.
enum Travel { case toward, away, unclear }

/// When a track's car arrives. A nil time means it isn't getting closer.
struct ArrivalEstimate: Equatable {
    let isTooNew: Bool
    let pointSeconds: Double?
    /// From the upper confidence bound on growth: the earliest plausible arrival. Decide uses this one.
    let lowSeconds: Double?
}

struct Track {
    let id: Int
    var box: CGRect
    let firstSeenSeconds: Double
    var lastSeenSeconds: Double
    var heights: [(t: Double, h: Double)]
    /// Boxes over `Config.directionWindowSeconds`: the screen's colors, and Decide's road and aim checks.
    var directionBoxes: [(t: Double, box: CGRect)] = []
    /// What it is; a track only ever matches detections of the same kind.
    var mover: Mover = .car

    /// Which way the car is going over the longer direction window: surely (even at the confidence bound) and at least
    /// `Config.awayMinShrinkPerSecond` of its height per second, so a parked car's jitter reads as neither.
    /// Decide takes a vehicle going either way as proof the camera looks along a road.
    var travel: Travel {
        let s = directionBoxes.map { (t: $0.t, h: Double($0.box.height)) }
        let n = Double(s.count)
        guard let first = s.first, let last = s.last, last.t - first.t >= Config.historySeconds, s.count >= 5 else { return .unclear }
        let tm = s.reduce(0) { $0 + $1.t } / n, hm = s.reduce(0) { $0 + $1.h } / n
        let stt = s.reduce(0) { $0 + ($1.t - tm) * ($1.t - tm) }
        guard stt > 0, hm > 0 else { return .unclear }
        let slope = s.reduce(0) { $0 + ($1.t - tm) * ($1.h - hm) } / stt
        let residualSquares = s.reduce(0) { sum, p in let e = p.h - hm - slope * (p.t - tm); return sum + e * e }
        let margin = Config.tauConfidenceSigmas * (residualSquares / (n - 2)).squareRoot() / stt.squareRoot()
        if slope + margin < 0 && slope / hm < -Config.awayMinShrinkPerSecond { return .away }
        if slope - margin > 0 && slope / hm > Config.awayMinShrinkPerSecond { return .toward }
        return .unclear
    }

    var isDrivingAway: Bool { travel == .away }

    /// A vehicle sliding across the picture without growing: the camera looks across the road, not along it. Cars
    /// coming along the road grow as they drift sideways; far cross streets and cars right at the curb are excluded
    /// by height.
    var isCrossingView: Bool {
        guard mover != .person, let first = directionBoxes.first, let last = directionBoxes.last else { return false }
        let seconds = last.t - first.t
        guard seconds >= Config.misaimMinSeconds, first.box.height > 0,
              last.box.height >= Config.misaimMinHeightFraction, last.box.height <= Config.misaimMaxHeightFraction,
              abs(last.box.height / first.box.height - 1) <= Config.misaimMaxGrowthFraction else { return false }
        let sideways = abs(last.box.midX - first.box.midX) / max(last.box.width, 1e-6) / seconds
        return sideways >= Config.misaimSidewaysBoxWidthsPerSecond
    }

    /// At a standstill: over at least `Config.historySeconds`, neither growing nor shrinking for sure, and its center
    /// moved less than `Config.stillMaxBoxWidthsPerSecond` box widths per second. Display only.
    var isStill: Bool {
        guard let first = directionBoxes.first, let last = directionBoxes.last, last.t - first.t >= Config.historySeconds,
              travel == .unclear else { return false }
        let moved = hypot(last.box.midX - first.box.midX, last.box.midY - first.box.midY) / max(last.box.width, 1e-6)
        return moved / (last.t - first.t) < Config.stillMaxBoxWidthsPerSecond
    }

    /// Time to arrival = height / growth per second, from a least-squares line over the last `Config.historySeconds`.
    func estimate(atSeconds now: Double) -> ArrivalEstimate {
        let s = heights.filter { $0.t >= lastSeenSeconds - Config.historySeconds }
        let n = Double(s.count)
        let tm = s.reduce(0) { $0 + $1.t } / n
        let stt = s.reduce(0) { $0 + ($1.t - tm) * ($1.t - tm) }
        guard lastSeenSeconds - firstSeenSeconds >= Config.historySeconds, s.count >= 3, stt > 0 else {
            return ArrivalEstimate(isTooNew: true, pointSeconds: nil, lowSeconds: nil)
        }
        let hm = s.reduce(0) { $0 + $1.h } / n
        let slope = s.reduce(0) { $0 + ($1.t - tm) * ($1.h - hm) } / stt
        let residualSquares = s.reduce(0) { sum, p in
            let e = p.h - hm - slope * (p.t - tm)
            return sum + e * e
        }
        let slopeError = (residualSquares / (n - 2)).squareRoot() / stt.squareRoot()
        // The fit measures growth at the window's midpoint; subtract the time since then.
        func tau(_ growth: Double) -> Double? { growth > 0 ? max(0, hm / growth - (now - tm)) : nil }
        return ArrivalEstimate(isTooNew: false, pointSeconds: tau(slope),
                               lowSeconds: tau(slope + Config.tauConfidenceSigmas * slopeError))
    }
}

/// Matches detections to tracks frame by frame. One per pipeline.
final class Tracker {
    private var tracks: [Track] = []
    private var nextId = 1
    private var orientation: CGImagePropertyOrientation?

    func update(_ detections: [Detection], atSeconds t: Double, orientation: CGImagePropertyOrientation) -> [Track] {
        if orientation != self.orientation {
            tracks = [] // heights from the old hold measure a different axis
            self.orientation = orientation
        }
        // A cyclist is a person box on a bicycle box; matching only within a kind keeps them from swapping tracks.
        let movers = detections.map { labelMover($0.label) ?? .car }
        var freeTracks = Set(tracks.indices)
        var freeDetections = Set(detections.indices)
        var pairs: [(track: Int, detection: Int)] = []
        func claim(_ candidates: [(Int, Int, Double)]) {
            for (i, j, _) in candidates where freeTracks.contains(i) && freeDetections.contains(j) {
                pairs.append((i, j))
                freeTracks.remove(i)
                freeDetections.remove(j)
            }
        }
        func scored(_ score: (CGRect, CGRect) -> Double) -> [(Int, Int, Double)] {
            freeTracks.flatMap { i in
                freeDetections.filter { tracks[i].mover == movers[$0] }.map { j in (i, j, score(tracks[i].box, detections[j].box)) }
            }
        }
        claim(scored(iou).filter { $0.2 >= Config.matchIoU }.sorted { $0.2 > $1.2 })
        claim(scored(boxDistance).filter { $0.2 <= Config.matchRadiusBoxSizes }.sorted { $0.2 < $1.2 })

        for (i, j) in pairs {
            let box = detections[j].box
            tracks[i].box = box
            tracks[i].lastSeenSeconds = t
            tracks[i].heights.append((t, box.height))
            tracks[i].heights.removeAll { $0.t < t - Config.historySeconds }
            tracks[i].directionBoxes.append((t, box))
            tracks[i].directionBoxes.removeAll { $0.t < t - Config.directionWindowSeconds }
        }
        for j in freeDetections.sorted() {
            let box = detections[j].box
            tracks.append(Track(id: nextId, box: box, firstSeenSeconds: t, lastSeenSeconds: t, heights: [(t, box.height)],
                                directionBoxes: [(t, box)], mover: movers[j]))
            nextId += 1
        }
        tracks.removeAll { t - $0.lastSeenSeconds > Config.trackLostSeconds }
        return tracks
    }
}

/// Distance between centers in sizes of box `a`, per axis, so normalized x and y scales don't mix.
private func boxDistance(_ a: CGRect, _ b: CGRect) -> Double {
    hypot((b.midX - a.midX) / a.width, (b.midY - a.midY) / a.height)
}
