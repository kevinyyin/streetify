import Foundation

/// Every tunable constant. Ask before changing any of them (see Pipeline/CLAUDE.md).
enum Config {
    /// Max tilt of the camera axis from horizontal; the center tile only spans about ±11° vertically.
    static let levelPitchToleranceDegrees = 8.0
    /// Max rotation about the camera axis.
    static let levelRollToleranceDegrees = 10.0
}
