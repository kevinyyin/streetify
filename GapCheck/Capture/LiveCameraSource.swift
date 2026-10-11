import AVFoundation
import CoreMotion

enum CaptureError: Error { case noCamera, noMultiCamFormat, cannotAdd }

/// One camera of the shared multi-cam session. Frames arrive on this source's own queue; late ones are dropped.
final class LiveCameraSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((Frame) -> Void)?

    let position: AVCaptureDevice.Position
    /// For AppModel to watch its system pressure (heat).
    let device: AVCaptureDevice
    private let motion: CMMotionManager
    private let level: LevelGate
    private let still: StillGate
    private let queue: DispatchQueue
    private var isRunning = false // only touched on `queue`
    private var lastSeconds = -Double.infinity

    init(session: AVCaptureMultiCamSession, position: AVCaptureDevice.Position, motion: CMMotionManager, level: LevelGate,
         still: StillGate) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw CaptureError.noCamera
        }
        self.device = device
        self.position = position
        self.motion = motion
        self.level = level
        self.still = still
        queue = DispatchQueue(label: position == .front ? "camera.front" : "camera.back")
        super.init()

        guard let format = device.formats.first(where: {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return $0.isMultiCamSupported && d.width == Config.captureWidthPixels && d.height == Config.captureHeightPixels
        }) else { throw CaptureError.noMultiCamFormat }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(output) else { throw CaptureError.cannotAdd }
        session.addInputWithNoConnections(input)
        session.addOutputWithNoConnections(output)
        try device.lockForConfiguration()
        device.activeFormat = format
        device.unlockForConfiguration()
        guard let port = input.ports(for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: position).first
        else { throw CaptureError.cannotAdd }
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else { throw CaptureError.cannotAdd }
        session.addConnection(connection)
        if position == .front {
            // Unmirrored buffers, so the front image Vision sees is mirrored only by its `…Mirrored` EXIF orientation.
            // Then the street lies in the left half of both cameras' pictures (Decide's turn-around check).
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
        }
    }

    func start() { queue.async { self.isRunning = true } }
    func stop() { queue.async { self.isRunning = false } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRunning, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard isDue(t, after: lastSeconds) else { return }
        lastSeconds = t
        // No motion data reads as not level, so Decide reports Unknown.
        let m = motion.deviceMotion
        let a = m.map { attitude(gravityX: $0.gravity.x, gravityY: $0.gravity.y, gravityZ: $0.gravity.z) }
        // An uncalibrated compass (or none) gives no heading, and the heading check simply doesn't run.
        let heading = m.flatMap { d -> Double? in
            guard d.magneticField.accuracy != .uncalibrated else { return nil }
            let f = d.magneticField.field
            return cameraHeadingDegrees(gravity: (d.gravity.x, d.gravity.y, d.gravity.z), field: (f.x, f.y, f.z))
        }
        // No motion data reads as still: not level already makes the side Unknown.
        let stillness = m.map { d -> (isStill: Bool, rmsG: Double) in
            let u = d.userAcceleration
            return still.update(accelerationG: (u.x * u.x + u.y * u.y + u.z * u.z).squareRoot(), atSeconds: t)
        }
        onFrame?(Frame(pixelBuffer: buffer, timestampSeconds: t,
                       orientation: exifOrientation(hold: a?.hold ?? .portrait, position: position),
                       isLevel: level.update(a), tiltErrorDegrees: a?.tiltErrorDegrees ?? 90, headingDegrees: heading,
                       isStill: stillness?.isStill ?? true, motionG: stillness?.rmsG ?? 0))
    }
}
