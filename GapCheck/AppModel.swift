import AVFoundation
import CoreImage
import CoreMotion
import Observation
import UIKit
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
    private(set) var isLevel = false
    private(set) var tiltErrorDegrees = 90.0
    /// True while the output volume is 0, so speech can't be heard.
    private(set) var isMuted = false
    /// False while VoiceOver is on (nobody sees the screen) unless launched with `-showOverlay`.
    private(set) var isPreviewOn = true

    private static let log = Logger(subsystem: "GapCheck", category: "capture")
    private static let heardHoldKey = "heardHoldInstructions"

    @ObservationIgnored private let session = AVCaptureMultiCamSession()
    /// Serial, so session starts never overlap.
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "session", qos: .userInitiated)
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let level = LevelGate()
    @ObservationIgnored private var pipelines: [Side: Pipeline] = [:]
    @ObservationIgnored private let ciContext = CIContext()
    @ObservationIgnored private let previewQueue = DispatchQueue(label: "preview", qos: .utility)
    /// Sides whose preview is being rendered; a frame arriving meanwhile is skipped.
    @ObservationIgnored private let previewBusy = OSAllocatedUnfairLock(initialState: Set<Side>())
    /// `isPreviewOn` for the pipeline queues.
    @ObservationIgnored private let previewOn = OSAllocatedUnfairLock(initialState: true)
    /// The outline model, one for both sides so only one outline runs at a time next to the detectors. Loaded the
    /// first time someone can see the screen, off the main thread (nil = failed). Only touched on `previewQueue`.
    @ObservationIgnored private lazy var segmenter = try? Segmenter()

    @ObservationIgnored private let haptics = Haptics()
    @ObservationIgnored private let tone = Tone()
    @ObservationIgnored private let speech = Speech()
    @ObservationIgnored private var lastAnnounced: [Side: DirectionState] = [.left: .unknown(.stale), .right: .unknown(.stale)]
    @ObservationIgnored private var isAnnouncementScheduled = false
    /// False until a frame has reported the tilt; before that (or with no camera, as in the simulator) the tone is silent.
    @ObservationIgnored private var hasLevelReading = false
    /// The compass's distance from the street heading, for the tone while a side is misaimed.
    @ObservationIgnored private var headingErrorDegrees: Double?
    @ObservationIgnored private var lastUpdateSeconds: [Side: Double] = [:]
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var grace: DispatchWorkItem?
    /// Faults the user can act on (permission, heat, camera in use) and when they were set (host seconds); a silent
    /// side reads its fault instead of stale.
    @ObservationIgnored private var cameraFaults: [Side: (reason: UnknownReason, sinceSeconds: Double)] = [:]
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var keyValueObservations: [NSKeyValueObservation] = []

    func start() {
        speech.currentStates = { [unowned self] in self.panes.mapValues(\.state) }
        startAudio()
        updatePreviewOn()
        observers.append(NotificationCenter.default.addObserver(forName: UIAccessibility.voiceOverStatusDidChangeNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.updatePreviewOn() })
        updateTone()
        // The live stale watchdog: wall clock, on main, independent of the pipeline queues it watches.
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        announceAfterGrace()
        if !UserDefaults.standard.bool(forKey: Self.heardHoldKey) {
            UserDefaults.standard.set(true, forKey: Self.heardHoldKey)
            speakHoldInstructions()
        }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        // The magnetic frame adds the compass for the heading check; without a magnetometer, level still works.
        if CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical) {
            motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical)
        } else {
            motion.startDeviceMotionUpdates()
        }
        observeCaptureSession()
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard granted else { return self.setFault(.noPermission, on: [.left, .right]) }
                self.startCameras()
            }
        }
    }

    /// Says the current status of both directions again (the screen's tap / VoiceOver action).
    func speakStatus() {
        speech.say([Utterance(side: nil, text: Strings.status(panes.mapValues(\.state)), priority: .car, replacesQueue: true)])
    }

    /// How to hold the phone (first launch, and the screen's long press / VoiceOver action). Unlike the status it doesn't
    /// restate the sides, so news it cuts off or holds up is said after it.
    func speakHoldInstructions() {
        speech.say([Utterance(side: nil, text: Strings.holdInstructions, priority: .car)])
    }

    /// The app went to the background, where the cameras stop: say so while it still can, instead of leaving the last
    /// "no cars" standing. Until it comes back nothing else is said and the tone is off. Not verified on device.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        let task = UIApplication.shared.beginBackgroundTask(withName: "say paused")
        haptics.play(.unknown)
        updateTone()
        speech.say([Utterance(side: nil, text: Strings.paused, priority: .car, replacesQueue: true)])
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.maxUtteranceSeconds) {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    /// Back in the foreground: nothing said before the pause still holds, so both sides start over from Unknown and
    /// their state is announced afresh (or "camera stopped" after the grace period).
    func resume() {
        guard isPaused else { return }
        isPaused = false
        for side in [Side.left, .right] {
            panes[side]?.state = silentSideState(fault: cameraFaults[side]?.reason)
            pipelines[side]?.noteStale()
        }
        lastAnnounced = [.left: .unknown(.stale), .right: .unknown(.stale)]
        lastUpdateSeconds = [:]
        updateTone()
        announceAfterGrace()
    }

    func replay(_ url: URL, on side: Side) {
        cameraFaults[side] = nil // replay frames carry file time, not host time, so they can't clear it themselves
        run(VideoFileSource(url: url, realTime: true), on: side)
    }

    private func startAudio() {
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.playback, options: [.mixWithOthers])
            try audio.setActive(true)
        } catch {
            // Speech may then follow the silent switch; the vibrations still work.
            Logger(subsystem: "GapCheck", category: "audio").error("audio session failed: \(error.localizedDescription)")
        }
        keyValueObservations.append(audio.observe(\.outputVolume, options: [.initial, .new]) { [weak self] audio, _ in
            let isMuted = audio.outputVolume == 0
            DispatchQueue.main.async { self?.setMuted(isMuted) }
        })
    }

    /// At volume 0 nothing spoken can be heard: one problem buzz says so, and the screen shows it.
    private func setMuted(_ muted: Bool) {
        if muted && !isMuted { haptics.play(.unknown) }
        isMuted = muted
    }

    private func updatePreviewOn() {
        let on = showsPreview(voiceOverRunning: UIAccessibility.isVoiceOverRunning, arguments: ProcessInfo.processInfo.arguments)
        previewOn.withLock { $0 = on }
        isPreviewOn = on
        if !on {
            for side in [Side.left, .right] {
                panes[side]?.image = nil
                panes[side]?.masks = []
            }
        }
    }

    private func startCameras() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return setFault(.unsupported, on: [.left, .right]) }
        let frontSide: Side = Config.frontCameraFacesLeft ? .left : .right
        let backSide: Side = frontSide == .left ? .right : .left
        let cameras: [(position: AVCaptureDevice.Position, side: Side)] = [(.back, backSide), (.front, frontSide)]
        for (position, side) in cameras {
            do {
                let camera = try LiveCameraSource(session: session, position: position, motion: motion, level: level)
                observePressure(camera.device)
                run(camera, on: side, detectsFaces: position == .front)
            } catch {
                // It never starts, so its side stays Unknown and is announced as stopped after the grace period.
                Self.log.error("camera \(position == .front ? "front" : "back") failed: \(error.localizedDescription)")
            }
        }
        Self.log.info("multi-cam hardwareCost \(self.session.hardwareCost), systemPressureCost \(self.session.systemPressureCost)")
        sessionQueue.async { self.session.startRunning() }
    }

    /// Interruptions (camera in use, heat) and runtime errors of the shared session.
    private func observeCaptureSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = raw.flatMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
            guard reason != .videoDeviceNotAvailableInBackground else { return } // pause() covers it
            // The fault stays until frames flow again (`show`), so the end of an interruption isn't "camera stopped".
            self?.setFault(interruptionFault(reason), on: [.left, .right])
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                                            queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            AppModel.log.error("capture runtime error: \(error?.localizedDescription ?? "unknown")")
            // A media services reset stops the session until it is restarted. Other errors would just fail again, so
            // the session stays stopped and the watchdog says so.
            guard error?.code == .mediaServicesWereReset else { return }
            self?.sessionQueue.async { self?.session.startRunning() }
        })
    }

    /// Heat: at "shutdown" the cameras stop, so say why before the watchdog can only say "camera stopped".
    private func observePressure(_ device: AVCaptureDevice) {
        keyValueObservations.append(device.observe(\.systemPressureState, options: [.new]) { [weak self] device, _ in
            let level = device.systemPressureState.level
            DispatchQueue.main.async {
                if level == .shutdown {
                    self?.setFault(.overheated, on: [.left, .right])
                } else if level == .critical {
                    AppModel.log.warning("system pressure critical")
                }
            }
        })
    }

    /// A camera fault the user can act on; the side reads it until frames flow again.
    private func setFault(_ reason: UnknownReason, on sides: [Side]) {
        for side in sides {
            cameraFaults[side] = (reason, CACurrentMediaTime())
            panes[side]?.state = .unknown(reason)
        }
        updateTone()
        scheduleAnnouncement()
    }

    private func run(_ source: FrameSource, on side: Side, detectsFaces: Bool = false) {
        pipelines[side]?.stop()
        guard let detector = try? Detector(detectsFaces: detectsFaces) else { return } // no model: no pipeline, the side stays Unknown
        let pipeline = Pipeline(side: side, source: source, detector: detector)
        pipeline.onUpdate = { [weak self] update in
            guard let self else { return }
            if let frame = update.frame, self.previewOn.withLock({ $0 }) { self.renderPreview(frame, side: side) }
            self.show(update)
        }
        pipelines[side] = pipeline
        pipeline.start()
    }

    /// Called on the pipeline's queue. Renders (and outlines) on its own queue and skips frames while busy, so drawing
    /// the screen never holds up the pipeline that makes the warnings.
    private func renderPreview(_ frame: Frame, side: Side) {
        guard previewBusy.withLock({ $0.insert(side).inserted }) else { return }
        previewQueue.async {
            // ponytail: first come first served across sides; take turns if one side's outlines starve.
            self.segmenter?.submit(frame) { masks in
                DispatchQueue.main.async {
                    guard self.isPreviewOn else { return }
                    self.panes[side]?.masks = masks
                }
            }
            let ci = CIImage(cvPixelBuffer: frame.pixelBuffer).oriented(frame.orientation)
            let image = self.ciContext.createCGImage(ci, from: ci.extent)
            self.previewBusy.withLock { _ = $0.remove(side) }
            DispatchQueue.main.async {
                guard let image, self.isPreviewOn else { return }
                self.panes[side]?.image = image
            }
        }
    }

    /// Called on the pipeline's queue.
    private func show(_ update: PipelineUpdate) {
        DispatchQueue.main.async {
            // A frame taken before a fault was set (in flight when it was) must not undo it. Live frame times are host
            // time, like the fault's; not verified on device.
            if let fault = self.cameraFaults[update.side] {
                guard let t = update.frame?.timestampSeconds, t > fault.sinceSeconds else { return }
                self.cameraFaults[update.side] = nil // frames are flowing again: the camera works
            }
            var pane = self.panes[update.side] ?? Pane()
            if let t = update.frame?.timestampSeconds {
                pane.timestampSeconds = t
                pane.redTrackIds = self.isPreviewOn ? redTrackIds(update.tracks, atSeconds: t, wasRed: pane.redTrackIds) : []
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
                self.headingErrorDegrees = update.headingErrorDegrees
            }
            self.updateTone()
            self.scheduleAnnouncement()
        }
    }

    /// Every 0.1 s on main: the stale watchdog (not while paused: `resume` starts both sides over) and the speech
    /// safety net.
    private func tick() {
        speech.poll()
        guard !isPaused else { return }
        for side in staleSides(lastUpdateSeconds: lastUpdateSeconds, nowSeconds: CACurrentMediaTime()) {
            let silent = silentSideState(fault: cameraFaults[side]?.reason)
            guard panes[side]?.state != silent else { continue }
            panes[side]?.state = silent
            pipelines[side]?.noteStale()
            updateTone()
            scheduleAnnouncement()
        }
    }

    private func updateTone() {
        guard hasLevelReading, !isPaused else { return tone.apply(ToneSettings(isOn: false, frequencyHz: 0)) }
        let isMisaimed = panes.values.contains { $0.state == .unknown(.misaimed) }
        tone.apply(toneSettings(isLevel: isLevel, tiltErrorDegrees: tiltErrorDegrees,
                                headingErrorDegrees: isMisaimed ? headingErrorDegrees : nil))
    }

    /// After the grace period, a side still stale was never announced (it started that way, or came back from a
    /// pause that way); forgetting it makes the next announcement say "camera stopped". A newer grace period (a quick
    /// pause and resume) replaces the old one, which would otherwise end early.
    private func announceAfterGrace() {
        grace?.cancel()
        let work = DispatchWorkItem {
            self.lastAnnounced = baselineAfterStartup(self.lastAnnounced)
            self.scheduleAnnouncement()
        }
        grace = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.startupGraceSeconds, execute: work)
    }

    /// The two cameras change state independently; wait a moment so changes landing together are one sentence.
    /// Nothing is announced while paused.
    private func scheduleAnnouncement() {
        guard !isPaused, !isAnnouncementScheduled else { return }
        isAnnouncementScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.announceCoalesceSeconds) {
            self.isAnnouncementScheduled = false
            guard !self.isPaused else { return }
            let current = self.panes.mapValues(\.state)
            let previous = self.lastAnnounced
            self.lastAnnounced = announcedBaseline(previous: previous, current: current)
            guard let event = announce(previous: previous, current: current) else { return }
            self.haptics.play(event.haptic)
            self.speech.say(event.utterances)
        }
    }
}

/// What a camera-session interruption means for the user.
func interruptionFault(_ reason: AVCaptureSession.InterruptionReason?) -> UnknownReason {
    switch reason {
    case .videoDeviceNotAvailableDueToSystemPressure?: return .overheated
    default: return .interrupted
    }
}
