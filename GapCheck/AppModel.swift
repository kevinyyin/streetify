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
        /// Display only, from the segmenter; may lag the image by a frame.
        var masks: [SegmentMask] = []
        /// Cars the screen draws red; kept from frame to frame (see `redTrackIds`).
        var redTrackIds: Set<Int> = []
    }

    var panes: [Side: Pane] = [.left: Pane(), .right: Pane()]

    @ObservationIgnored private let session = AVCaptureMultiCamSession()
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let level = LevelGate()
    @ObservationIgnored private var pipelines: [Side: Pipeline] = [:]
    @ObservationIgnored private let ciContext = CIContext()

    @ObservationIgnored private let haptics = Haptics()
    @ObservationIgnored private let tone = Tone()
    @ObservationIgnored private let speech = Speech()
    @ObservationIgnored private var lastAnnounced: [Side: DirectionState] = [.left: .unknown(.stale), .right: .unknown(.stale)]
    @ObservationIgnored private var isAnnouncementScheduled = false
    private(set) var isLevel = false
    /// False until a frame has reported the tilt; before that (or with no camera, as in the simulator) the tone is silent.
    @ObservationIgnored private var hasLevelReading = false
    private(set) var tiltErrorDegrees = 90.0
    @ObservationIgnored private var lastUpdateSeconds: [Side: Double] = [:]
    @ObservationIgnored private var watchdog: Timer?

    func start() {
        speech.currentStates = { [unowned self] in self.panes.mapValues(\.state) }
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

    /// Says the current status of both directions again (the screen's tap / VoiceOver action).
    func speakStatus() {
        speech.say([Utterance(side: nil, text: Strings.status(panes.mapValues(\.state)), priority: .car)])
    }

    func replay(_ url: URL, on side: Side) {
        run(VideoFileSource(url: url, realTime: true), on: side)
    }

    private func startCameras() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return } // pre-XS phone: both sides stay Unknown
        let frontSide: Side = Config.frontCameraFacesLeft ? .left : .right
        let backSide: Side = frontSide == .left ? .right : .left
        // A camera that fails to configure never starts, so its side stays Unknown.
        if let back = try? LiveCameraSource(session: session, position: .back, motion: motion, level: level) { run(back, on: backSide) }
        if let front = try? LiveCameraSource(session: session, position: .front, motion: motion, level: level) { run(front, on: frontSide) }
        Logger(subsystem: "GapCheck", category: "capture")
            .info("multi-cam hardwareCost \(self.session.hardwareCost), systemPressureCost \(self.session.systemPressureCost)")
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    private func run(_ source: FrameSource, on side: Side) {
        pipelines[side]?.stop()
        guard let detector = try? Detector() else { return } // no model: no pipeline, the side stays Unknown
        let pipeline = Pipeline(side: side, source: source, detector: detector)
        // Masks are for the screen only; the segmenter skips frames while busy, so it never holds up the warnings.
        let segmenter = try? Segmenter()
        segmenter?.onMasks = { [weak self] masks in DispatchQueue.main.async { self?.panes[side]?.masks = masks } }
        pipeline.onUpdate = { [weak self] update in
            if let frame = update.frame { segmenter?.submit(frame) }
            self?.show(update)
        }
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
            if let t = update.frame?.timestampSeconds {
                pane.timestampSeconds = t
                pane.redTrackIds = redTrackIds(update.tracks, atSeconds: t, wasRed: pane.redTrackIds)
            }
            pane.detections = update.detections
            pane.tracks = update.tracks
            pane.state = update.state
            self.panes[update.side] = pane
            self.lastUpdateSeconds[update.side] = CACurrentMediaTime()

            if let frame = update.frame {
                if frame.isLevel && !self.isLevel { self.haptics.play(.ready) }
                self.isLevel = frame.isLevel
                self.hasLevelReading = true
                self.tiltErrorDegrees = frame.tiltErrorDegrees
            }
            self.updateTone()
            self.scheduleAnnouncement()
        }
    }

    private func markSilentSidesStale() {
        speech.poll()
        for side in staleSides(lastUpdateSeconds: lastUpdateSeconds, nowSeconds: CACurrentMediaTime())
        where panes[side]?.state != .unknown(.stale) {
            panes[side]?.state = .unknown(.stale)
            updateTone()
            scheduleAnnouncement()
        }
    }

    private func updateTone() {
        guard hasLevelReading else { return tone.apply(ToneSettings(isOn: false, frequencyHz: 0)) }
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
            self.speech.say(event.utterances)
        }
    }
}
