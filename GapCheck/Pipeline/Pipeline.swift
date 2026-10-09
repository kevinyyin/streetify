import Foundation

struct PipelineUpdate {
    let side: Side
    let frame: Frame?
    let detections: [Detection]
}

/// Source → Detect for one camera on its own serial queue. Shares no state with the other pipeline.
final class Pipeline {
    let side: Side
    var onUpdate: ((PipelineUpdate) -> Void)?

    private let source: FrameSource
    private let detector: Detector
    private let queue: DispatchQueue

    init(side: Side, source: FrameSource, detector: Detector) {
        self.side = side
        self.source = source
        self.detector = detector
        queue = DispatchQueue(label: "pipeline.\(side)")
        // sync: the source waits while we work, so late camera frames get dropped instead of queueing up.
        source.onFrame = { [weak self] frame in self?.queue.sync { self?.process(frame) } }
    }

    func start() { source.start() }
    func stop() { source.stop() }

    private func process(_ frame: Frame) {
        guard let detections = try? detector.detect(frame) else { return }
        onUpdate?(PipelineUpdate(side: side, frame: frame, detections: detections))
    }
}
