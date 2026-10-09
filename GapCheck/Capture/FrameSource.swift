import CoreVideo
import ImageIO

/// One camera frame plus how it was taken.
struct Frame {
    let pixelBuffer: CVPixelBuffer
    let timestampSeconds: Double
    let orientation: CGImagePropertyOrientation
    let isLevel: Bool
    let tiltErrorDegrees: Double
}

protocol FrameSource: AnyObject {
    var onFrame: ((Frame) -> Void)? { get set }
    var isLive: Bool { get }
    func start()
    func stop()
}
