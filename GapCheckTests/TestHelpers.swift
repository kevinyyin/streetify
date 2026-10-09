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
