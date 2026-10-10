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

    /// COCO classes that count as vehicles; speech calls them "car" unless they are bikes.
    static let vehicleLabels: Set<String> = ["car", "truck", "bus", "motorcycle", "bicycle"]
    /// Vehicles spoken as "bike".
    static let bikeLabels: Set<String> = ["motorcycle", "bicycle"]
    /// COCO classes tracked as people: coming only once measured; otherwise they hide the road (rule 7).
    static let personLabels: Set<String> = ["person"]
    /// Label given to the front camera's face boxes; never tracked.
    static let faceLabel = "face"
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
    /// Clear only after rules 1 to 8 have been quiet this long.
    static let clearHoldSeconds = 1.5
    /// Stationary vehicles covering more than this fraction of the tile block the view.
    static let blockedFraction = 0.3
    /// With no moving vehicle seen for this long, an empty picture no longer reads "no cars" but "no road seen".
    static let roadEvidenceSeconds = 300.0
    /// While tilted, a car seen this recently is still reported ("car", no time).
    static let tiltCarMemorySeconds = 1.0

    /// Faces covering this fraction of the front camera's picture mean the screen faces the user.
    static let faceMinAreaFraction = 0.05
    /// A car sliding sideways at least this many box widths per second without growing crosses the view: misaimed.
    static let misaimSidewaysBoxWidthsPerSecond = 1.0
    /// Seconds of a track's boxes needed before it can count as crossing.
    static let misaimMinSeconds = 0.5
    /// A crossing car changes height by at most this fraction over that time; an approaching one grows.
    static let misaimMaxGrowthFraction = 0.2
    /// Crossing cars are at least this tall (fraction of the picture), so a far cross street doesn't count.
    static let misaimMinHeightFraction = 0.05
    /// And at most this tall, so a car passing right at the curb doesn't count.
    static let misaimMaxHeightFraction = 0.3
    /// After crossing traffic is seen, the side reads misaimed this long.
    static let misaimMemorySeconds = 10.0
    /// The compass may drift this far from the locked street heading before the side reads misaimed.
    static let headingToleranceDegrees = 25.0
    /// The camera axis's horizontal part below this (pointing steeply up or down) gives no heading.
    static let headingMinHorizontalFraction = 0.5

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
    /// A sentence not reported finished after this long counts as done, so the next one can play.
    static let maxUtteranceSeconds = 4.0
    /// Changes landing this close together are spoken as one sentence (the two cameras run independently).
    static let announceCoalesceSeconds = 0.2
    /// While a side reads "no cars", a soft tick after this much quiet says the app is still watching.
    static let heartbeatSeconds = 10.0

    /// Screen only: a car whose time to arrival is this or less turns red; Decide and speech don't use it.
    static let dangerHighlightSeconds = 8.0
    /// Screen only: height history for telling a car driving away; longer than historySeconds so slow shrinking shows.
    static let directionWindowSeconds = 4.0
    /// Screen only: a car shrinking (growing) at least this fraction of its height per second is driving away (toward us).
    static let awayMinShrinkPerSecond = 0.03
    /// Screen only: a car whose center moves less than this many box widths per second is at a standstill.
    static let stillMaxBoxWidthsPerSecond = 0.1
    /// Screen only: a red car at most this many box widths to the side of a smaller car counts as in front of it.
    static let lineMaxGapBoxWidths = 1.5
    /// Screen only: segmentation masks below this confidence are not drawn.
    static let minMaskConfidence: Float = 0.25

    /// Luma sampling step for the image-quality check.
    static let qualityStridePixels = 4
    /// Mean luma (0...1) below this is too dark. Calibrate on Footage.
    static let minMeanLuma = 0.08
    /// Mean luma (0...1) above this is too bright. Calibrate on Footage.
    static let maxMeanLuma = 0.95
    /// Laplacian variance (0...255 luma) below this means the lens is covered. Calibrate on Footage.
    static let minLaplacianVariance = 10.0
    /// The center tile is checked in this many cells per side, so a finger over part of the lens shows.
    static let qualityGridCells = 4
    /// A flat tile cell darker than this fraction of the frame's mean luma is covered (sky is flat but bright).
    static let coveredCellRelativeLuma = 0.5
    /// This many covered tile cells mean something is over part of the lens. Calibrate on Footage.
    static let coveredMinCells = 2
}
