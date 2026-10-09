import CoreML
import CoreVideo
import Vision

/// A vehicle box. `box` is Vision-normalized in the oriented image, origin bottom-left.
struct Detection: Equatable {
    let box: CGRect
    let label: String
    let confidence: Float
}

struct ImageQuality {
    /// 0...1.
    let meanLuma: Double
    /// Variance of a 4-neighbour Laplacian on 0...255 luma, sampled every `Config.qualityStridePixels`.
    let laplacianVariance: Double
}

func imageQuality(_ buffer: CVPixelBuffer) -> ImageQuality {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    // An unreadable buffer reads as dark and flat, so Decide reports Unknown.
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return ImageQuality(meanLuma: 0, laplacianVariance: 0) }
    let p = base.assumingMemoryBound(to: UInt8.self)
    let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
    let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let s = Config.qualityStridePixels
    var lumaSum = 0.0, lapSum = 0.0, lapSquareSum = 0.0, n = 0.0
    for y in stride(from: s, to: height - s, by: s) {
        for x in stride(from: s, to: width - s, by: s) {
            let c = Double(p[y * row + x])
            let lap = Double(p[(y - s) * row + x]) + Double(p[(y + s) * row + x])
                + Double(p[y * row + x - s]) + Double(p[y * row + x + s]) - 4 * c
            lumaSum += c
            lapSum += lap
            lapSquareSum += lap * lap
            n += 1
        }
    }
    guard n > 0 else { return ImageQuality(meanLuma: 0, laplacianVariance: 0) }
    let lapMean = lapSum / n
    return ImageQuality(meanLuma: lumaSum / n / 255, laplacianVariance: lapSquareSum / n - lapMean * lapMean)
}

/// YOLO11n through Vision. One per pipeline; call from that pipeline's queue only.
final class Detector {
    private let wholeRequest: VNCoreMLRequest

    init() throws {
        let model = try VNCoreMLModel(for: yolo11n(configuration: MLModelConfiguration()).model)
        wholeRequest = VNCoreMLRequest(model: model)
        wholeRequest.imageCropAndScaleOption = .scaleFit // the default .centerCrop drops the frame edges, where close cars are
    }

    func detect(_ frame: Frame) throws -> [Detection] {
        try VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: frame.orientation).perform([wholeRequest])
        return vehicles(wholeRequest.results)
    }
}

private func vehicles(_ results: [VNObservation]?) -> [Detection] {
    (results as? [VNRecognizedObjectObservation] ?? []).compactMap { o in
        guard let top = o.labels.first, Config.vehicleLabels.contains(top.identifier),
              o.confidence >= Config.minDetectionConfidence else { return nil }
        return Detection(box: o.boundingBox, label: top.identifier, confidence: o.confidence)
    }
}
