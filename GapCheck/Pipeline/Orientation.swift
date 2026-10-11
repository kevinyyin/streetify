import CoreML
import Vision

/// A car box cropped to the picture (Vision-normalized); nil when none of it is inside. Vision throws on a region of
/// interest outside the image, which would make the frame stale.
func clampedCrop(_ box: CGRect) -> CGRect? {
    let crop = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    return crop.isNull || crop.isEmpty ? nil : crop
}

/// CFV ConvNeXt (Apache-2.0; `tools/export_car_orientation.py`): which way a car faces the camera. Trained on parked
/// cars about 3 m away, never checked on traffic, so stage 1 only shows its verdict on the debug screen
/// (`Config.directionModelSuppressesRearCars`). One per pipeline; call from that pipeline's queue only.
final class CarOrientationClassifier {
    private let request: VNCoreMLRequest
    private static let rearLabels: Set<String> = ["back-left", "back", "back-right"]

    init() throws {
        request = VNCoreMLRequest(model: try VNCoreMLModel(for: CarOrientation(configuration: MLModelConfiguration()).model))
        request.imageCropAndScaleOption = .scaleFill // training resized each whole crop to 224x224
    }

    /// Probability (0...1) that the car in `box` (Vision-normalized) is seen from behind: back-left + back + back-right.
    func rearProbability(_ frame: Frame, box: CGRect) throws -> Double {
        guard let crop = clampedCrop(box) else { return 0 }
        request.regionOfInterest = crop
        try VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: frame.orientation).perform([request])
        guard let results = request.results as? [VNClassificationObservation] else { throw DetectError.unexpectedResults }
        return results.filter { Self.rearLabels.contains($0.identifier) }.reduce(0) { $0 + Double($1.confidence) }
    }
}
