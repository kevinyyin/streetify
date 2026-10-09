import Foundation

/// Every tunable constant, in one place.
enum Config {
    /// Max tilt of the camera axis from horizontal; the center tile only spans about ±11° vertically.
    static let levelPitchToleranceDegrees = 8.0
    /// Max rotation about the camera axis.
    static let levelRollToleranceDegrees = 10.0

    /// COCO classes that count as vehicles.
    static let vehicleLabels: Set<String> = ["car", "truck", "bus", "motorcycle", "bicycle"]
    /// Detections below this confidence are ignored; lower means more detections.
    static let minDetectionConfidence: Float = 0.25

    /// Luma sampling step for the image-quality check.
    static let qualityStridePixels = 4
    /// Mean luma (0...1) below this is too dark. Calibrate on Footage.
    static let minMeanLuma = 0.08
    /// Mean luma (0...1) above this is too bright. Calibrate on Footage.
    static let maxMeanLuma = 0.95
    /// Laplacian variance (0...255 luma) below this means the lens is covered. Calibrate on Footage.
    static let minLaplacianVariance = 10.0
}
