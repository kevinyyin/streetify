import AVFoundation
import CoreMotion

enum CaptureError: Error { case noCamera, noMultiCamFormat, cannotAdd }

/// One camera of the shared multi-cam session. Frames arrive on this source's own queue; late ones are dropped.
final class LiveCameraSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((Frame) -> Void)?

    private let position: AVCaptureDevice.Position
    private let motion: CMMotionManager
    private let level: LevelGate
    private let queue: DispatchQueue
    private var isRunning = false // only touched on `queue`
    private var lastSeconds = -Double.infinity

    init(session: AVCaptureMultiCamSession, position: AVCaptureDevice.Position, motion: CMMotionManager, level: LevelGate) throws {
        self.position = position
        self.motion = motion
        self.level = level
        queue = DispatchQueue(label: position == .front ? "camera.front" : "camera.back")
        super.init()

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw CaptureError.noCamera
        }
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
    }

    func start() { queue.async { self.isRunning = true } }
    func stop() { queue.async { self.isRunning = false } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRunning, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard isDue(t, after: lastSeconds) else { return }
        lastSeconds = t
        // No motion data reads as not level, so Decide reports Unknown.
        let a = motion.deviceMotion.map { attitude(gravityX: $0.gravity.x, gravityY: $0.gravity.y, gravityZ: $0.gravity.z) }
        onFrame?(Frame(pixelBuffer: buffer, timestampSeconds: t,
                       orientation: exifOrientation(hold: a?.hold ?? .portrait, position: position),
                       isLevel: level.update(a), tiltErrorDegrees: a?.tiltErrorDegrees ?? 90))
    }
}
