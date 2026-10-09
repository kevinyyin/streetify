import Foundation

/// Every tunable constant, in one place.
enum Config {
    /// Frames per second each pipeline processes; extra camera frames are dropped.
    static let processFps = 10.0
    /// Requested camera resolution, landscape sensor pixels.
    static let captureWidthPixels: Int32 = 1920
    static let captureHeightPixels: Int32 = 1080
    /// The screen faces left down the road, so the front camera watches left and the back camera right.
    static let frontCameraFacesLeft = true

    /// Max tilt of the camera axis from horizontal; the center tile only spans about ±11° vertically.
    static let levelPitchToleranceDegrees = 8.0
    /// Max rotation about the camera axis.
    static let levelRollToleranceDegrees = 10.0
    /// Once not level, it counts as level again only within these, so a wobble near the limit doesn't flip it.
    static let levelReturnPitchToleranceDegrees = 6.0
    static let levelReturnRollToleranceDegrees = 8.0

    /// COCO classes that count as vehicles.
    static let vehicleLabels: Set<String> = ["car", "truck", "bus", "motorcycle", "bicycle"]
    /// COCO classes that can hide the road (rule 5) but are never tracked as cars.
    static let blockerLabels: Set<String> = ["person"]
    /// Detections below this confidence are ignored; lower means more detections.
    static let minDetectionConfidence: Float = 0.25

    /// Side of the centered square run at full resolution for far cars; matches the model input.
    static let tileSizePixels = 640
    /// A tile box this close to the tile edge (fraction of tile size) is treated as cut off.
    static let tileEdgeMarginFraction = 0.01
    /// Whole-frame and tile boxes overlapping at least this much are the same car.
    static let mergeIoU = 0.5

    /// Track and detection overlapping at least this much are the same car.
    static let matchIoU = 0.3
    /// Otherwise, the nearest center within this many box sizes (per axis) is the same car.
    static let matchRadiusBoxSizes = 1.0
    /// A track unmatched this long is dropped; shorter gaps ride out missed detections.
    static let trackLostSeconds = 0.5
    /// Height history used for the time-to-arrival fit; younger tracks are "too new" (Approaching, far).
    static let historySeconds = 1.5
    /// A car arriving sooner than this is Approaching.
    static let approachWindowSeconds = 20.0
    /// Decide on growth + this many standard errors, so noisy far cars stay Approaching.
    static let tauConfidenceSigmas = 2.0

    /// No processed frame for this long means Unknown (stale).
    static let staleFrameTimeoutSeconds = 0.3
    /// Clear only after rules 1 to 5 have been quiet this long.
    static let clearHoldSeconds = 1.5
    /// Stationary vehicles covering more than this fraction of the tile block the view.
    static let blockedFraction = 0.3

    /// The tone (only while not level): low pitch at this tilt or more, rising to aimMaxHz near level.
    static let aimMaxErrorDegrees = 45.0
    static let aimMinHz = 200.0
    static let aimMaxHz = 500.0
    /// Tone loudness, 0...1 of full scale.
    static let toneAmplitude: Float = 0.25
    /// After this long, a side that never produced a state is announced as stopped.
    static let startupGraceSeconds = 3.0
    /// A car's time is spoken once more when it drops to this many seconds or fewer.
    static let closeWarningSeconds = 5.0
    /// After a close warning, a time this much higher is treated as the next car and spoken; less is the same car.
    static let newCarJumpSeconds = 3.0
    /// Changes landing this close together are spoken as one sentence (the two cameras run independently).
    static let announceCoalesceSeconds = 0.2

    /// Luma sampling step for the image-quality check.
    static let qualityStridePixels = 4
    /// Mean luma (0...1) below this is too dark. Calibrate on Footage.
    static let minMeanLuma = 0.08
    /// Mean luma (0...1) above this is too bright. Calibrate on Footage.
    static let maxMeanLuma = 0.95
    /// Laplacian variance (0...255 luma) below this means the lens is covered. Calibrate on Footage.
    static let minLaplacianVariance = 10.0
}
