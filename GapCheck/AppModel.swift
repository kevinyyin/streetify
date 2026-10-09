import AVFoundation
import CoreImage
import CoreMotion
import Observation

/// Owns the cameras, motion and pipelines; publishes what the screen shows. UI state lives on main.
@Observable
final class AppModel {
    struct Pane {
        var image: CGImage?
        var detections: [Detection] = []
    }

    var panes: [Side: Pane] = [.left: Pane(), .right: Pane()]

    @ObservationIgnored private let session = AVCaptureMultiCamSession()
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var pipelines: [Side: Pipeline] = [:]
    @ObservationIgnored private let ciContext = CIContext()

    func start() {
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates()
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { return } // no camera: both sides stay Unknown
            DispatchQueue.main.async { self.startCameras() }
        }
    }

    func replay(_ url: URL, on side: Side) {
        run(VideoFileSource(url: url, realTime: true), on: side)
    }

    private func startCameras() {
        if let back = try? LiveCameraSource(session: session, position: .back, motion: motion) {
            run(back, on: .right)
        }
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    private func run(_ source: FrameSource, on side: Side) {
        pipelines[side]?.stop()
        guard let detector = try? Detector() else { return } // no model: no pipeline, the side stays Unknown
        let pipeline = Pipeline(side: side, source: source, detector: detector)
        pipeline.onUpdate = { [weak self] in self?.show($0) }
        pipelines[side] = pipeline
        pipeline.start()
    }

    /// Called on the pipeline's queue.
    private func show(_ update: PipelineUpdate) {
        let image = update.frame.flatMap { frame -> CGImage? in
            let ci = CIImage(cvPixelBuffer: frame.pixelBuffer).oriented(frame.orientation)
            return ciContext.createCGImage(ci, from: ci.extent)
        }
        DispatchQueue.main.async {
            var pane = self.panes[update.side] ?? Pane()
            if let image { pane.image = image }
            pane.detections = update.detections
            self.panes[update.side] = pane
        }
    }
}
