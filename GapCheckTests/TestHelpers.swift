import CoreVideo
import ImageIO
@testable import GapCheck

/// A 420f buffer whose luma comes from `luma(x, y)`; chroma is neutral.
func makeLumaBuffer(width: Int, height: Int, luma: (Int, Int) -> UInt8) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &buffer)
    let b = buffer!
    CVPixelBufferLockBaseAddress(b, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
    let yRow = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    for row in 0..<height { for col in 0..<width { y[row * yRow + col] = luma(col, row) } }
    let uv = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt8.self)
    let uvRow = CVPixelBufferGetBytesPerRowOfPlane(b, 1)
    for row in 0..<height / 2 { for col in 0..<width { uv[row * uvRow + col] = 128 } }
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

func makeFrame(_ buffer: CVPixelBuffer, atSeconds t: Double = 0) -> Frame {
    Frame(pixelBuffer: buffer, timestampSeconds: t, orientation: .up, isLevel: true, tiltErrorDegrees: 0)
}

/// Deterministic RNG so noisy tests are repeatable.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Heights of a car arriving `tau` s after the last sample: h(t) = hEnd·τ/(τ + tEnd − t), at Config.processFps.
/// Noise is uniform ±`noisePixels` on a 1920 px axis.
func approachingHeights(tauAtEndSeconds tau: Double, heightAtEnd hEnd: Double, durationSeconds: Double = 1.5,
                        noisePixels: Double = 0, seed: UInt64 = 1) -> [(t: Double, h: Double)] {
    var rng = SplitMix64(state: seed)
    let n = Int((durationSeconds * Config.processFps).rounded())
    return (0...n).map { i in
        let t = Double(i) / Config.processFps
        let noise = noisePixels == 0 ? 0 : Double.random(in: -noisePixels...noisePixels, using: &rng) / 1920
        return (t, hEnd * tau / (tau + durationSeconds - t) + noise)
    }
}

func parkedHeights(height: Double, noisePixels: Double, seed: UInt64) -> [(t: Double, h: Double)] {
    var rng = SplitMix64(state: seed)
    return (0...15).map { i in (Double(i) / Config.processFps, height + Double.random(in: -noisePixels...noisePixels, using: &rng) / 1920) }
}

func makeTrack(_ heights: [(t: Double, h: Double)], box: CGRect? = nil, id: Int = 1) -> Track {
    let h = heights.last!.h
    return Track(id: id, box: box ?? CGRect(x: 0.5 - h, y: 0.5, width: 2 * h, height: h),
                 firstSeenSeconds: heights.first!.t, lastSeenSeconds: heights.last!.t, heights: heights)
}

func car(_ box: CGRect) -> Detection { Detection(box: box, label: "car", confidence: 0.9) }

/// A track whose direction window (4 s at the processing rate) follows `heightAt(seconds)`, centered and not sliding.
func trackWithDirection(heightAt: (Double) -> Double, id: Int = 1) -> Track {
    var track = makeTrack(parkedHeights(height: heightAt(4), noisePixels: 0, seed: 1), id: id)
    track.directionBoxes = (0...40).map { i in
        let t = Double(i) / Config.processFps, h = heightAt(t)
        return (t, CGRect(x: 0.5 - h, y: 0.4, width: 2 * h, height: h))
    }
    return track
}
