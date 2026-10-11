import Foundation
import os

/// Sides whose last update (host seconds) is older than the stale timeout. Run from main, never a pipeline queue,
/// so a pipeline that hangs mid-frame, or a replay that ends or never starts, still goes stale.
func staleSides(lastUpdateSeconds: [Side: Double], nowSeconds: Double) -> [Side] {
    [Side.left, .right].filter { side in
        lastUpdateSeconds[side].map { nowSeconds - $0 > Config.staleFrameTimeoutSeconds } ?? false
    }
}

/// What a silent side reads: the camera fault when one is known, else stale.
func silentSideState(fault: UnknownReason?) -> DirectionState {
    .unknown(fault ?? .stale)
}

struct PipelineUpdate {
    let side: Side
    let frame: Frame?
    let detections: [Detection]
    let tracks: [Track]
    let state: DirectionState
    /// Compass error from the locked street heading, for the tone.
    var headingErrorDegrees: Double? = nil
}

/// Source → Detect → Track → Decide for one camera on its own serial queue. Shares no state with the other pipeline.
final class Pipeline {
    let side: Side
    var onUpdate: ((PipelineUpdate) -> Void)?

    private let source: FrameSource
    private let detector: Detector
    private let orientation: CarOrientationClassifier?
    private static let log = Logger(subsystem: "GapCheck", category: "orientation")
    private let tracker = Tracker()
    private let decider: Decider
    private let queue: DispatchQueue

    /// `checksTurnAround`: live cameras only; replayed footage was filmed any way round.
    init(side: Side, source: FrameSource, detector: Detector, orientation: CarOrientationClassifier? = nil,
         checksTurnAround: Bool = false) {
        self.side = side
        self.orientation = orientation
        decider = Decider(checksTurnAround: checksTurnAround)
        self.source = source
        self.detector = detector
        queue = DispatchQueue(label: "pipeline.\(side)")
        // sync: the source waits while we work, so late camera frames get dropped instead of queueing up.
        source.onFrame = { [weak self] frame in self?.queue.sync { self?.process(frame) } }
    }

    /// Frame gaps go stale here, on frame timestamps; silence (no updates at all) goes stale in AppModel's watchdog.
    func start() { source.start() }
    func stop() { source.stop() }

    /// The live watchdog found this side silent; the next Clear waits the full hold. Call from any queue.
    func noteStale() { queue.async { self.decider.noteExternalStale() } }

    private func process(_ frame: Frame) {
        // A frame whose detection throws never reaches Decide, so the watchdog or the next gap reports stale.
        guard let found = try? detector.detect(frame) else { return }
        let detections = found.filter { Config.vehicleLabels.contains($0.label) }
        var tracks = tracker.update(detections, atSeconds: frame.timestampSeconds, orientation: frame.orientation)
        if let orientation { tracks = noteRear(frame, tracks, orientation) }
        let observation = FrameObservation(timestampSeconds: frame.timestampSeconds, isLevel: frame.isLevel,
                                           quality: imageQuality(frame.pixelBuffer), tile: frameTileRect(frame),
                                           blockerBoxes: found.filter { Config.blockerLabels.contains($0.label) }.map(\.box),
                                           faceBoxes: found.filter { $0.label == Config.faceLabel }.map(\.box),
                                           headingDegrees: frame.headingDegrees, isStill: frame.isStill)
        let state = decider.update(observation, tracks: tracks)
        onUpdate?(PipelineUpdate(side: side, frame: frame, detections: detections, tracks: tracks, state: state,
                                 headingErrorDegrees: decider.headingErrorDegrees))
    }

    /// The front/rear model on the largest too-new cars big enough for it, a few per frame (stage 1: the screen only).
    private func noteRear(_ frame: Frame, _ tracks: [Track], _ classifier: CarOrientationClassifier) -> [Track] {
        let heightPixels = orientedSizePixels(frame).height
        let candidates = tracks
            .filter { Double($0.box.height) * heightPixels >= Config.directionModelMinHeightPixels }
            .filter { $0.estimate(atSeconds: frame.timestampSeconds).isTooNew }
            .sorted { $0.box.height > $1.box.height }
            .prefix(Config.directionModelMaxCropsPerFrame)
        guard !candidates.isEmpty else { return tracks }
        var probabilities: [Int: Double] = [:]
        for track in candidates {
            guard let p = try? classifier.rearProbability(frame, box: track.box) else { continue }
            probabilities[track.id] = p
            Self.log.debug("track \(track.id) rear \(p, format: .fixed(precision: 2))")
        }
        return tracker.noteRear(probabilities)
    }
}
