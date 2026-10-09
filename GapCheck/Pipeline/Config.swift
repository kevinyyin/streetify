import Foundation

/// Every tunable constant, in one place.
enum Config {
    /// Max tilt of the camera axis from horizontal; the center tile only spans about ±11° vertically.
    static let levelPitchToleranceDegrees = 8.0
    /// Max rotation about the camera axis.
    static let levelRollToleranceDegrees = 10.0
}
