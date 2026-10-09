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
    func start()
    func stop()
}

/// True when a frame at `t` keeps the rate at `Config.processFps`; the 0.9 absorbs camera timestamp jitter.
func isDue(_ t: Double, after lastSeconds: Double) -> Bool {
    t - lastSeconds >= 0.9 / Config.processFps
}
