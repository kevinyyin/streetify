import CoreGraphics
import ImageIO

/// Which way a car is going along the camera axis, over `Config.directionWindowSeconds`.
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
    /// Boxes over `Config.directionWindowSeconds`, for `travel`: the screen's colors and Decide's road evidence.
    var directionBoxes: [(t: Double, box: CGRect)] = []

    /// Which way the car is going over the longer direction window: surely (even at the confidence bound) and at least
    /// `Config.awayMinShrinkPerSecond` of its height per second, so a parked car's jitter reads as neither. Decide takes either as proof of a road.
    var travel: Travel {
        let s = directionBoxes.map { (t: $0.t, h: Double($0.box.height)) }
        guard let first = s.first, let last = s.last, last.t - first.t >= Config.historySeconds, s.count >= 5,
              let fit = fitLine(s), fit.hm > 0 else { return .unclear }
        let margin = Config.tauConfidenceSigmas * fit.slopeError
        if fit.slope + margin < 0 && fit.slope / fit.hm < -Config.awayMinShrinkPerSecond { return .away }
        if fit.slope - margin > 0 && fit.slope / fit.hm > Config.awayMinShrinkPerSecond { return .toward }
        return .unclear
    }

    var isDrivingAway: Bool { travel == .away }

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
        guard lastSeenSeconds - firstSeenSeconds >= Config.historySeconds, let fit = fitLine(s) else {
            return ArrivalEstimate(isTooNew: true, pointSeconds: nil, lowSeconds: nil)
        }
        // The fit measures growth at the window's midpoint; subtract the time since then.
        func tau(_ growth: Double) -> Double? { growth > 0 ? max(0, fit.hm / growth - (now - fit.tm)) : nil }
        return ArrivalEstimate(isTooNew: false, pointSeconds: tau(fit.slope),
                               lowSeconds: tau(fit.slope + Config.tauConfidenceSigmas * fit.slopeError))
    }
}

/// Least-squares line through height over time: mean time and height, slope, and the slope's standard error.
/// Nil with fewer than 3 points or no spread in time.
private func fitLine(_ s: [(t: Double, h: Double)]) -> (tm: Double, hm: Double, slope: Double, slopeError: Double)? {
    let n = Double(s.count)
    let tm = s.reduce(0) { $0 + $1.t } / n
    let stt = s.reduce(0) { $0 + ($1.t - tm) * ($1.t - tm) }
    guard s.count >= 3, stt > 0 else { return nil }
    let hm = s.reduce(0) { $0 + $1.h } / n
    let slope = s.reduce(0) { $0 + ($1.t - tm) * ($1.h - hm) } / stt
    let residualSquares = s.reduce(0) { sum, p in
        let e = p.h - hm - slope * (p.t - tm)
        return sum + e * e
    }
    return (tm, hm, slope, (residualSquares / (n - 2)).squareRoot() / stt.squareRoot())
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
        claim(freeTracks.flatMap { i in freeDetections.map { j in (i, j, iou(tracks[i].box, detections[j].box)) } }
            .filter { $0.2 >= Config.matchIoU }.sorted { $0.2 > $1.2 })
        claim(freeTracks.flatMap { i in freeDetections.map { j in (i, j, boxDistance(tracks[i].box, detections[j].box)) } }
            .filter { $0.2 <= Config.matchRadiusBoxSizes }.sorted { $0.2 < $1.2 })

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
                                directionBoxes: [(t, box)]))
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
