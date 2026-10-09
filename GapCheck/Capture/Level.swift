import AVFoundation
import ImageIO

/// How the phone is held, named like UIDeviceOrientation.
enum Hold {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight

    /// Where gravity points, in device x/y, when held this way and level.
    var downAxis: (x: Double, y: Double) {
        switch self {
        case .portrait: return (0, -1)
        case .portraitUpsideDown: return (0, 1)
        case .landscapeLeft: return (-1, 0)
        case .landscapeRight: return (1, 0)
        }
    }
}

struct Attitude: Equatable {
    let hold: Hold
    let pitchDegrees: Double
    let rollDegrees: Double

    var isLevel: Bool {
        abs(pitchDegrees) <= Config.levelPitchToleranceDegrees && abs(rollDegrees) <= Config.levelRollToleranceDegrees
    }

    var tiltErrorDegrees: Double { max(abs(pitchDegrees), abs(rollDegrees)) }
}

/// Level with a buffer: once not level, it counts as level again only within the tighter return limits,
/// so a hand wobbling near the limit doesn't flip the state every frame.
func isLevel(_ a: Attitude, wasLevel: Bool) -> Bool {
    let pitchLimit = wasLevel ? Config.levelPitchToleranceDegrees : Config.levelReturnPitchToleranceDegrees
    let rollLimit = wasLevel ? Config.levelRollToleranceDegrees : Config.levelReturnRollToleranceDegrees
    return abs(a.pitchDegrees) <= pitchLimit && abs(a.rollDegrees) <= rollLimit
}

/// Gravity in device coordinates (CMDeviceMotion.gravity) to hold, pitch and roll.
func attitude(gravityX x: Double, gravityY y: Double, gravityZ z: Double) -> Attitude {
    let hold: Hold = abs(x) > abs(y)
        ? (x < 0 ? .landscapeLeft : .landscapeRight)
        : (y < 0 ? .portrait : .portraitUpsideDown)
    let length = (x * x + y * y + z * z).squareRoot()
    let pitch = asin(max(-1, min(1, z / length))) * 180 / .pi
    let down = hold.downAxis
    let roll = atan2(x * down.y - y * down.x, x * down.x + y * down.y) * 180 / .pi
    return Attitude(hold: hold, pitchDegrees: pitch, rollDegrees: roll)
}

/// EXIF orientation to hand Vision for a camera's buffers. From Apple's Vision samples; not verified on device.
func exifOrientation(hold: Hold, position: AVCaptureDevice.Position) -> CGImagePropertyOrientation {
    switch (hold, position) {
    case (.portrait, .front): return .leftMirrored
    case (.portraitUpsideDown, .front): return .rightMirrored
    case (.landscapeLeft, .front): return .downMirrored
    case (.landscapeRight, .front): return .upMirrored
    case (.portrait, _): return .right
    case (.portraitUpsideDown, _): return .left
    case (.landscapeLeft, _): return .up
    case (.landscapeRight, _): return .down
    }
}
