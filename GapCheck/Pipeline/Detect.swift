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

/// The centered `Config.tileSizePixels` square where far cars appear, Vision-normalized.
/// Clamped to the image: Vision throws on a region of interest outside it, which would make every frame stale.
func tileRect(orientedWidthPixels w: Double, orientedHeightPixels h: Double) -> CGRect {
    let tile = Double(Config.tileSizePixels)
    let width = min(1, tile / w), height = min(1, tile / h)
    return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
}

/// A box normalized to the tile, back in whole-frame coordinates.
func mapFromTile(_ box: CGRect, tile: CGRect) -> CGRect {
    CGRect(x: tile.minX + box.minX * tile.width, y: tile.minY + box.minY * tile.height,
           width: box.width * tile.width, height: box.height * tile.height)
}

func iou(_ a: CGRect, _ b: CGRect) -> Double {
    let overlap = a.intersection(b)
    guard !overlap.isNull else { return 0 }
    let i = overlap.width * overlap.height
    return i / (a.width * a.height + b.width * b.height - i)
}

/// Whole-frame and tile boxes (already mapped) as one list. A tile box replaces the whole-frame box it overlaps,
/// unless it touches the tile edge, where the car is cut off and its height is wrong.
func merge(whole: [Detection], tile: [Detection], tileRect: CGRect) -> [Detection] {
    var result = whole
    let marginX = Config.tileEdgeMarginFraction * tileRect.width
    let marginY = Config.tileEdgeMarginFraction * tileRect.height
    for t in tile {
        let touchesEdge = t.box.minX - tileRect.minX <= marginX || tileRect.maxX - t.box.maxX <= marginX
            || t.box.minY - tileRect.minY <= marginY || tileRect.maxY - t.box.maxY <= marginY
        if let i = result.firstIndex(where: { iou($0.box, t.box) >= Config.mergeIoU }) {
            if !touchesEdge { result[i] = t }
        } else {
            result.append(t)
        }
    }
    return result
}

/// YOLO11n through Vision. One per pipeline; call from that pipeline's queue only.
final class Detector {
    private let wholeRequest: VNCoreMLRequest
    private let tileRequest: VNCoreMLRequest

    init() throws {
        let model = try VNCoreMLModel(for: yolo11n(configuration: MLModelConfiguration()).model)
        wholeRequest = VNCoreMLRequest(model: model)
        wholeRequest.imageCropAndScaleOption = .scaleFit // the default .centerCrop drops the frame edges, where close cars are
        tileRequest = VNCoreMLRequest(model: model)
        tileRequest.imageCropAndScaleOption = .scaleFit
    }

    func detect(_ frame: Frame) throws -> [Detection] {
        let found = try detectSeparately(frame)
        return merge(whole: found.whole, tile: found.tile, tileRect: tileRequest.regionOfInterest)
    }

    /// Both requests' vehicles; tile boxes are mapped to whole-frame coordinates.
    func detectSeparately(_ frame: Frame) throws -> (whole: [Detection], tile: [Detection]) {
        let tile = frameTileRect(frame)
        tileRequest.regionOfInterest = tile
        try VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: frame.orientation)
            .perform([wholeRequest, tileRequest])
        let tileBoxes = try vehicles(tileRequest.results).map {
            Detection(box: mapFromTile($0.box, tile: tile), label: $0.label, confidence: $0.confidence)
        }
        return (try vehicles(wholeRequest.results), tileBoxes)
    }
}

/// The tile for a frame in its oriented (upright) dimensions.
func frameTileRect(_ frame: Frame) -> CGRect {
    let w = Double(CVPixelBufferGetWidth(frame.pixelBuffer)), h = Double(CVPixelBufferGetHeight(frame.pixelBuffer))
    switch frame.orientation {
    case .left, .right, .leftMirrored, .rightMirrored: return tileRect(orientedWidthPixels: h, orientedHeightPixels: w)
    default: return tileRect(orientedWidthPixels: w, orientedHeightPixels: h)
    }
}

enum DetectError: Error { case unexpectedResults }

/// Vehicle boxes from a request's results. Anything but object observations throws, so the frame goes stale
/// instead of reading as "no cars".
func vehicles(_ results: [VNObservation]?) throws -> [Detection] {
    guard let objects = results as? [VNRecognizedObjectObservation] else { throw DetectError.unexpectedResults }
    return objects.compactMap { o in
        guard let top = o.labels.first, Config.vehicleLabels.contains(top.identifier),
              o.confidence >= Config.minDetectionConfidence else { return nil }
        return Detection(box: o.boundingBox, label: top.identifier, confidence: o.confidence)
    }
}
