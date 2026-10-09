import Foundation

/// Every tunable constant. Ask before changing any of them (see Pipeline/CLAUDE.md).
enum Config {
    /// Frames per second each pipeline processes; extra camera frames are dropped.
    static let processFps = 10.0
    /// Requested camera resolution, landscape sensor pixels.
    static let captureWidthPixels: Int32 = 1920
    static let captureHeightPixels: Int32 = 1080

    /// Max tilt of the camera axis from horizontal; the center tile only spans about ±11° vertically.
    static let levelPitchToleranceDegrees = 8.0
    /// Max rotation about the camera axis.
    static let levelRollToleranceDegrees = 10.0

    /// COCO classes that count as vehicles.
    static let vehicleLabels: Set<String> = ["car", "truck", "bus", "motorcycle", "bicycle"]
    /// Detections below this confidence are ignored; lower means more detections.
    static let minDetectionConfidence: Float = 0.25

    /// Side of the centered square run at full resolution for far cars; matches the model input.
    static let tileSizePixels = 640
    /// A tile box this close to the tile edge (fraction of tile size) is treated as cut off.
    static let tileEdgeMarginFraction = 0.01
    /// Whole-frame and tile boxes overlapping at least this much are the same car.
    static let mergeIoU = 0.5

    /// Luma sampling step for the image-quality check.
    static let qualityStridePixels = 4
    /// Mean luma (0...1) below this is too dark. Calibrate on Footage.
    static let minMeanLuma = 0.08
    /// Mean luma (0...1) above this is too bright. Calibrate on Footage.
    static let maxMeanLuma = 0.95
    /// Laplacian variance (0...255 luma) below this means the lens is covered. Calibrate on Footage.
    static let minLaplacianVariance = 10.0
}
