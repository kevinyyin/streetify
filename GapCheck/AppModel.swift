import AVFoundation
import CoreImage
import CoreMotion
import Observation
import os

/// Owns the cameras, motion and pipelines; publishes what the screen shows. UI state lives on main.
@Observable
final class AppModel {
    struct Pane {
        var image: CGImage?
        var detections: [Detection] = []
        var tracks: [Track] = []
        var timestampSeconds = 0.0
        var state: DirectionState = .unknown(.stale)
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
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return } // pre-XS phone: both sides stay Unknown
        let frontSide: Side = Config.frontCameraFacesLeft ? .left : .right
        let backSide: Side = frontSide == .left ? .right : .left
        // A camera that fails to configure never starts, so its side stays Unknown.
        if let back = try? LiveCameraSource(session: session, position: .back, motion: motion) { run(back, on: backSide) }
        if let front = try? LiveCameraSource(session: session, position: .front, motion: motion) { run(front, on: frontSide) }
        Logger(subsystem: "GapCheck", category: "capture")
            .info("multi-cam hardwareCost \(self.session.hardwareCost), systemPressureCost \(self.session.systemPressureCost)")
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
            if let t = update.frame?.timestampSeconds { pane.timestampSeconds = t }
            pane.detections = update.detections
            pane.tracks = update.tracks
            pane.state = update.state
            self.panes[update.side] = pane
        }
    }
}
