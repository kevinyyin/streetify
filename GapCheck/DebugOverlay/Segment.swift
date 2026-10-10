import CoreML
import Vision

/// One object's outline for the screen. Display only: Decide and speech never see masks.
struct SegmentMask {
    /// Vision-normalized in the oriented image, origin bottom-left; the area `image` covers.
    let box: CGRect
    /// White where the object is, transparent elsewhere; the screen tints it.
    let image: CGImage
}

/// YOLO11n-seg on its own queue, for the screen. A frame that arrives while it is busy is skipped, so it never queues
/// up behind the warnings; it still shares the Neural Engine with them, so AppModel runs it only when someone can see
/// the screen.
final class Segmenter {
    var onMasks: (([SegmentMask]) -> Void)?

    private let request: VNCoreMLRequest
    private let queue = DispatchQueue(label: "segment", qos: .utility)
    private let lock = NSLock()
    private var isBusy = false

    init() throws {
        let model = try VNCoreMLModel(for: yolo11n_seg(configuration: MLModelConfiguration()).model)
        request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit
    }

    /// Call from any queue; returns at once.
    func submit(_ frame: Frame) {
        lock.lock()
        guard !isBusy else { return lock.unlock() }
        isBusy = true
        lock.unlock()
        queue.async {
            let masks = (try? self.segment(frame)) ?? []
            self.lock.lock()
            self.isBusy = false
            self.lock.unlock()
            self.onMasks?(masks)
        }
    }

    private func segment(_ frame: Frame) throws -> [SegmentMask] {
        try VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: frame.orientation).perform([request])
        let arrays = (request.results as? [VNCoreMLFeatureValueObservation] ?? []).compactMap(\.featureValue.multiArrayValue)
        guard let predictions = arrays.first(where: { $0.shape.count == 3 }),
              let protos = arrays.first(where: { $0.shape.count == 4 }) else { return [] }
        let w = Double(CVPixelBufferGetWidth(frame.pixelBuffer)), h = Double(CVPixelBufferGetHeight(frame.pixelBuffer))
        let isSideways = [.left, .right, .leftMirrored, .rightMirrored].contains(frame.orientation)
        return decodeSegments(predictions: floats(predictions), protos: floats(protos),
                              anchorCount: predictions.shape[2].intValue, protoSize: protos.shape[3].intValue,
                              imageWidth: isSideways ? h : w, imageHeight: isSideways ? w : h)
    }
}

/// COCO class ids drawn on screen: person, bicycle, car, motorcycle, bus, truck.
private let maskedClassIds = [0, 1, 2, 3, 5, 7]
private let modelInputPixels = 640.0
private let maskCoefficientCount = 32
private let classCount = 80

/// Turns raw YOLO-seg output into masks. `predictions` is [4 box + 80 classes + 32 coefficients] × anchors, boxes
/// in model-input pixels; `protos` is 32 × protoSize × protoSize. The model saw the image letterboxed (scaleFit).
func decodeSegments(predictions p: [Float], protos: [Float], anchorCount n: Int, protoSize: Int,
                    imageWidth: Double, imageHeight: Double) -> [SegmentMask] {
    struct Candidate { let anchor: Int; let score: Float; let rect: CGRect } // rect in model-input pixels, top-left origin
    var candidates: [Candidate] = []
    for a in 0..<n {
        guard let score = maskedClassIds.map({ p[(4 + $0) * n + a] }).max(), score >= Config.minMaskConfidence else { continue }
        let cx = Double(p[a]), cy = Double(p[n + a]), bw = Double(p[2 * n + a]), bh = Double(p[3 * n + a])
        candidates.append(Candidate(anchor: a, score: score, rect: CGRect(x: cx - bw / 2, y: cy - bh / 2, width: bw, height: bh)))
    }
    var kept: [Candidate] = []
    for c in candidates.sorted(by: { $0.score > $1.score }) where kept.count < 30 {
        if !kept.contains(where: { iou($0.rect, c.rect) > 0.5 }) { kept.append(c) }
    }

    let scale = min(modelInputPixels / imageWidth, modelInputPixels / imageHeight)
    let padX = (modelInputPixels - imageWidth * scale) / 2, padY = (modelInputPixels - imageHeight * scale) / 2
    let protoScale = Double(protoSize) / modelInputPixels
    let plane = protoSize * protoSize
    return kept.compactMap { c in
        // The box on the proto grid, clamped to the part of the input that is image, not padding.
        let x0 = max(Int((max(c.rect.minX, padX) * protoScale).rounded(.down)), 0)
        let y0 = max(Int((max(c.rect.minY, padY) * protoScale).rounded(.down)), 0)
        let x1 = min(Int((min(c.rect.maxX, modelInputPixels - padX) * protoScale).rounded(.up)), protoSize)
        let y1 = min(Int((min(c.rect.maxY, modelInputPixels - padY) * protoScale).rounded(.up)), protoSize)
        guard x1 > x0, y1 > y0 else { return nil }
        let coefficients = (0..<maskCoefficientCount).map { p[(4 + classCount + $0) * n + c.anchor] }
        var pixels = [UInt8](repeating: 0, count: (x1 - x0) * (y1 - y0) * 4)
        for y in y0..<y1 {
            for x in x0..<x1 {
                var sum: Float = 0
                for k in 0..<maskCoefficientCount { sum += coefficients[k] * protos[k * plane + y * protoSize + x] }
                guard sum > 0 else { continue } // sigmoid(sum) > 0.5
                let i = ((y - y0) * (x1 - x0) + (x - x0)) * 4
                pixels[i] = 255; pixels[i + 1] = 255; pixels[i + 2] = 255; pixels[i + 3] = 255
            }
        }
        guard let image = rgbaImage(pixels, width: x1 - x0, height: y1 - y0) else { return nil }
        // Proto grid → model input → image pixels → Vision-normalized, origin bottom-left.
        func imageX(_ gx: Int) -> Double { (Double(gx) / protoScale - padX) / scale / imageWidth }
        func imageY(_ gy: Int) -> Double { (Double(gy) / protoScale - padY) / scale / imageHeight }
        let box = CGRect(x: imageX(x0), y: 1 - imageY(y1), width: imageX(x1) - imageX(x0), height: imageY(y1) - imageY(y0))
        return SegmentMask(box: box, image: image)
    }
}

private func rgbaImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

/// An output array as Floats, in logical order whatever its strides or element type.
private func floats(_ array: MLMultiArray) -> [Float] {
    (array.dataType == .float32 ? MLShapedArray<Float>(array) : MLShapedArray<Float>(converting: array)).scalars
}
