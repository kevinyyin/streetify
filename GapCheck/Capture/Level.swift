import AVFoundation
import ImageIO
import os

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

/// One level buffer for the whole phone, shared by both cameras so they never disagree about level.
final class LevelGate {
    private let wasLevel = OSAllocatedUnfairLock(initialState: false)

    /// Feeds one motion reading (nil = no motion data, which reads as not level) and returns the buffered state.
    func update(_ a: Attitude?) -> Bool {
        wasLevel.withLock { was in
            was = a.map { isLevel($0, wasLevel: was) } ?? false
            return was
        }
    }
}

/// Curb only: whether the phone is held still, from the user acceleration (gravity removed). One gate for both cameras,
/// like `LevelGate`. Still again only after `Config.historySeconds` without a moving sample, so the arrival-time fit
/// never holds frames taken while walking.
final class StillGate {
    private struct Samples {
        var squares: [(t: Double, squareG: Double)] = []
        var latestSeconds = -Double.infinity
        var lastMovingSeconds = -Double.infinity
    }
    private let samples = OSAllocatedUnfairLock(initialState: Samples())

    /// Feeds one sample (userAcceleration magnitude in g, at frame time) and returns whether the phone is still, and the
    /// RMS over `Config.stillWindowSeconds`. Samples may arrive slightly out of order (two cameras).
    func update(accelerationG: Double, atSeconds t: Double) -> (isStill: Bool, rmsG: Double) {
        samples.withLock { s in
            s.latestSeconds = max(s.latestSeconds, t)
            s.squares.append((t, accelerationG * accelerationG))
            s.squares.removeAll { $0.t < s.latestSeconds - Config.stillWindowSeconds }
            let rms = s.squares.isEmpty ? 0 : (s.squares.reduce(0) { $0 + $1.squareG } / Double(s.squares.count)).squareRoot()
            if rms > Config.movingAccelerationG { s.lastMovingSeconds = max(s.lastMovingSeconds, t) }
            return (s.latestSeconds - s.lastMovingSeconds >= Config.historySeconds, rms)
        }
    }
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

/// Compass heading (degrees clockwise from magnetic north) of the back camera's axis, from gravity and the magnetic
/// field, both in device coordinates (CMDeviceMotion). The front camera looks the opposite way; Decide only compares
/// a heading with itself, so either camera can use it. Nil when the camera points too steeply up or down to have one.
func cameraHeadingDegrees(gravity g: (x: Double, y: Double, z: Double), field m: (x: Double, y: Double, z: Double)) -> Double? {
    typealias Vector = (x: Double, y: Double, z: Double)
    func cross(_ a: Vector, _ b: Vector) -> Vector { (a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) }
    func unit(_ v: Vector) -> Vector? {
        let length = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return length > 1e-9 ? (v.x / length, v.y / length, v.z / length) : nil
    }
    guard let down = unit(g), let east = unit(cross(down, m)) else { return nil }
    let north = cross(east, down)
    // The back camera looks along device −z.
    let e = -east.z, n = -north.z
    guard (e * e + n * n).squareRoot() >= Config.headingMinHorizontalFraction else { return nil }
    let degrees = atan2(e, n) * 180 / .pi
    return degrees < 0 ? degrees + 360 : degrees
}

/// The smaller angle between two headings, 0...180.
func angleDifferenceDegrees(_ a: Double, _ b: Double) -> Double {
    abs(remainder(a - b, 360))
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
