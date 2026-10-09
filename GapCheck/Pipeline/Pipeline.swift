import CoreMedia
import Foundation

struct PipelineUpdate {
    let side: Side
    /// nil when the stale watchdog fired with no new frame.
    let frame: Frame?
    let detections: [Detection]
    let tracks: [Track]
    let state: DirectionState
}

/// Source → Detect → Track → Decide for one camera on its own serial queue. Shares no state with the other pipeline.
final class Pipeline {
    let side: Side
    var onUpdate: ((PipelineUpdate) -> Void)?

    private let source: FrameSource
    private let detector: Detector
    private let tracker = Tracker()
    private let decider = Decider()
    private let queue: DispatchQueue
    private var watchdog: DispatchSourceTimer?

    init(side: Side, source: FrameSource, detector: Detector) {
        self.side = side
        self.source = source
        self.detector = detector
        queue = DispatchQueue(label: "pipeline.\(side)")
        // sync: the source waits while we work, so late camera frames get dropped instead of queueing up.
        source.onFrame = { [weak self] frame in self?.queue.sync { self?.process(frame) } }
    }

    func start() {
        if source.isLive {
            // The only wall-clock timing: live frames carry host-clock timestamps, so stale is measured on that clock.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 0.1)
            timer.setEventHandler { [weak self] in self?.checkStale() }
            timer.resume()
            watchdog = timer
        }
        source.start()
    }

    func stop() {
        source.stop()
        watchdog?.cancel()
        watchdog = nil
    }

    private func checkStale() {
        let before = decider.state
        let after = decider.checkStale(nowSeconds: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        if after != before { onUpdate?(PipelineUpdate(side: side, frame: nil, detections: [], tracks: [], state: after)) }
    }

    private func process(_ frame: Frame) {
        // A frame whose detection throws never reaches Decide, so the watchdog or the next gap reports stale.
        guard let detections = try? detector.detect(frame) else { return }
        let tracks = tracker.update(detections, atSeconds: frame.timestampSeconds, orientation: frame.orientation)
        let observation = FrameObservation(timestampSeconds: frame.timestampSeconds, isLevel: frame.isLevel,
                                           quality: imageQuality(frame.pixelBuffer), tile: frameTileRect(frame))
        let state = decider.update(observation, tracks: tracks)
        onUpdate?(PipelineUpdate(side: side, frame: frame, detections: detections, tracks: tracks, state: state))
    }
}
