import AVFoundation
import CoreImage
import CoreMotion
import Observation
import os

/// Owns the cameras, motion, pipelines and feedback; publishes what the screen shows. UI state lives on main.
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

    @ObservationIgnored private let haptics = Haptics()
    @ObservationIgnored private let tone = Tone()
    @ObservationIgnored private let speech = Speech()
    @ObservationIgnored private var lastAnnounced: [Side: DirectionState] = [.left: .unknown(.stale), .right: .unknown(.stale)]
    @ObservationIgnored private var isAnnouncementScheduled = false
    @ObservationIgnored private var isLevel = false
    @ObservationIgnored private var tiltErrorDegrees = 90.0
    @ObservationIgnored private var lastUpdateSeconds: [Side: Double] = [:]
    @ObservationIgnored private var watchdog: Timer?

    func start() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        updateTone()
        // The live stale watchdog: wall clock, on main, independent of the pipeline queues it watches.
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.markSilentSidesStale() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.startupGraceSeconds) {
            self.lastAnnounced = baselineAfterStartup(self.lastAnnounced)
            self.scheduleAnnouncement()
        }
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
            self.lastUpdateSeconds[update.side] = CACurrentMediaTime()

            if let frame = update.frame {
                if frame.isLevel && !self.isLevel { self.haptics.play(.ready) }
                self.isLevel = frame.isLevel
                self.tiltErrorDegrees = frame.tiltErrorDegrees
            }
            self.updateTone()
            self.scheduleAnnouncement()
        }
    }

    private func markSilentSidesStale() {
        for side in staleSides(lastUpdateSeconds: lastUpdateSeconds, nowSeconds: CACurrentMediaTime())
        where panes[side]?.state != .unknown(.stale) {
            panes[side]?.state = .unknown(.stale)
            updateTone()
            scheduleAnnouncement()
        }
    }

    private func updateTone() {
        tone.apply(toneSettings(isLevel: isLevel, tiltErrorDegrees: tiltErrorDegrees))
    }

    /// The two cameras change state independently; wait a moment so changes landing together are one sentence.
    private func scheduleAnnouncement() {
        guard !isAnnouncementScheduled else { return }
        isAnnouncementScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.announceCoalesceSeconds) {
            self.isAnnouncementScheduled = false
            let current = self.panes.mapValues(\.state)
            let previous = self.lastAnnounced
            self.lastAnnounced = announcedBaseline(previous: previous, current: current)
            guard let event = announce(previous: previous, current: current) else { return }
            self.haptics.play(event.haptic)
            self.speech.say(event.text)
        }
    }
}
