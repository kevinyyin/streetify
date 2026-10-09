//
// yolo11n_seg.swift
//
// This file was automatically generated and should not be edited.
//

import CoreML


/// Model Prediction Input Type
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, visionOS 1.0, *)
class yolo11n_segInput : MLFeatureProvider {

    /// image as color (kCVPixelFormatType_32BGRA) image buffer, 640 pixels wide by 640 pixels high
    var image: CVPixelBuffer

    var featureNames: Set<String> { ["image"] }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName == "image" {
            return MLFeatureValue(pixelBuffer: image)
        }
        return nil
    }

    init(image: CVPixelBuffer) {
        self.image = image
    }

    convenience init(imageWith image: CGImage) throws {
        self.init(image: try MLFeatureValue(cgImage: image, pixelsWide: 640, pixelsHigh: 640, pixelFormatType: kCVPixelFormatType_32ARGB, options: nil).imageBufferValue!)
    }

    convenience init(imageAt image: URL) throws {
        self.init(image: try MLFeatureValue(imageAt: image, pixelsWide: 640, pixelsHigh: 640, pixelFormatType: kCVPixelFormatType_32ARGB, options: nil).imageBufferValue!)
    }

    func setImage(with image: CGImage) throws  {
        self.image = try MLFeatureValue(cgImage: image, pixelsWide: 640, pixelsHigh: 640, pixelFormatType: kCVPixelFormatType_32ARGB, options: nil).imageBufferValue!
    }

    func setImage(with image: URL) throws  {
        self.image = try MLFeatureValue(imageAt: image, pixelsWide: 640, pixelsHigh: 640, pixelFormatType: kCVPixelFormatType_32ARGB, options: nil).imageBufferValue!
    }

}


/// Model Prediction Output Type
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, visionOS 1.0, *)
class yolo11n_segOutput : MLFeatureProvider {

    /// Source provided by CoreML
    private let provider : MLFeatureProvider

    /// var_1324 as 1 × 116 × 8400 3-dimensional array of floats
    var var_1324: MLMultiArray {
        provider.featureValue(for: "var_1324")!.multiArrayValue!
    }

    /// var_1324 as 1 × 116 × 8400 3-dimensional array of floats
    var var_1324ShapedArray: MLShapedArray<Float> {
        MLShapedArray<Float>(var_1324)
    }

    /// var_1362 as 1 × 32 × 160 × 160 4-dimensional array of floats
    var var_1362: MLMultiArray {
        provider.featureValue(for: "var_1362")!.multiArrayValue!
    }

    /// var_1362 as 1 × 32 × 160 × 160 4-dimensional array of floats
    var var_1362ShapedArray: MLShapedArray<Float> {
        MLShapedArray<Float>(var_1362)
    }

    var featureNames: Set<String> {
        provider.featureNames
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        provider.featureValue(for: featureName)
    }

    init(var_1324: MLMultiArray, var_1362: MLMultiArray) {
        self.provider = try! MLDictionaryFeatureProvider(dictionary: ["var_1324" : MLFeatureValue(multiArray: var_1324), "var_1362" : MLFeatureValue(multiArray: var_1362)])
    }

    init(features: MLFeatureProvider) {
        self.provider = features
    }
}


/// Class for model loading and prediction
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, visionOS 1.0, *)
class yolo11n_seg {
    let model: MLModel

    /// URL of model assuming it was installed in the same bundle as this class
    class var urlOfModelInThisBundle : URL {
        let bundle = Bundle(for: self)
        return bundle.url(forResource: "yolo11n-seg", withExtension:"mlmodelc")!
    }

    /**
        Construct yolo11n_seg instance with an existing MLModel object.

        Usually the application does not use this initializer unless it makes a subclass of yolo11n_seg.
        Such application may want to use `MLModel(contentsOfURL:configuration:)` and `yolo11n_seg.urlOfModelInThisBundle` to create a MLModel object to pass-in.

        - parameters:
          - model: MLModel object
    */
    init(model: MLModel) {
        self.model = model
    }

    /**
        Construct a model with configuration

        - parameters:
           - configuration: the desired model configuration

        - throws: an NSError object that describes the problem
    */
    convenience init(configuration: MLModelConfiguration = MLModelConfiguration()) throws {
        try self.init(contentsOf: type(of:self).urlOfModelInThisBundle, configuration: configuration)
    }

    /**
        Construct yolo11n_seg instance with explicit path to mlmodelc file
        - parameters:
           - modelURL: the file url of the model

        - throws: an NSError object that describes the problem
    */
    convenience init(contentsOf modelURL: URL) throws {
        try self.init(model: MLModel(contentsOf: modelURL))
    }

    /**
        Construct a model with URL of the .mlmodelc directory and configuration

        - parameters:
           - modelURL: the file url of the model
           - configuration: the desired model configuration

        - throws: an NSError object that describes the problem
    */
    convenience init(contentsOf modelURL: URL, configuration: MLModelConfiguration) throws {
        try self.init(model: MLModel(contentsOf: modelURL, configuration: configuration))
    }

    /**
        Construct yolo11n_seg instance asynchronously with optional configuration.

        Model loading may take time when the model content is not immediately available (e.g. encrypted model). Use this factory method especially when the caller is on the main thread.

        - parameters:
          - configuration: the desired model configuration
          - handler: the completion handler to be called when the model loading completes successfully or unsuccessfully
    */
    class func load(configuration: MLModelConfiguration = MLModelConfiguration(), completionHandler handler: @escaping (Swift.Result<yolo11n_seg, Error>) -> Void) {
        load(contentsOf: self.urlOfModelInThisBundle, configuration: configuration, completionHandler: handler)
    }

    /**
        Construct yolo11n_seg instance asynchronously with optional configuration.

        Model loading may take time when the model content is not immediately available (e.g. encrypted model). Use this factory method especially when the caller is on the main thread.

        - parameters:
          - configuration: the desired model configuration
    */
    class func load(configuration: MLModelConfiguration = MLModelConfiguration()) async throws -> yolo11n_seg {
        try await load(contentsOf: self.urlOfModelInThisBundle, configuration: configuration)
    }

    /**
        Construct yolo11n_seg instance asynchronously with URL of the .mlmodelc directory with optional configuration.

        Model loading may take time when the model content is not immediately available (e.g. encrypted model). Use this factory method especially when the caller is on the main thread.

        - parameters:
          - modelURL: the URL to the model
          - configuration: the desired model configuration
          - handler: the completion handler to be called when the model loading completes successfully or unsuccessfully
    */
    class func load(contentsOf modelURL: URL, configuration: MLModelConfiguration = MLModelConfiguration(), completionHandler handler: @escaping (Swift.Result<yolo11n_seg, Error>) -> Void) {
        MLModel.load(contentsOf: modelURL, configuration: configuration) { result in
            switch result {
            case .failure(let error):
                handler(.failure(error))
            case .success(let model):
                handler(.success(yolo11n_seg(model: model)))
            }
        }
    }

    /**
        Construct yolo11n_seg instance asynchronously with URL of the .mlmodelc directory with optional configuration.

        Model loading may take time when the model content is not immediately available (e.g. encrypted model). Use this factory method especially when the caller is on the main thread.

        - parameters:
          - modelURL: the URL to the model
          - configuration: the desired model configuration
    */
    class func load(contentsOf modelURL: URL, configuration: MLModelConfiguration = MLModelConfiguration()) async throws -> yolo11n_seg {
        let model = try await MLModel.load(contentsOf: modelURL, configuration: configuration)
        return yolo11n_seg(model: model)
    }

    /**
        Make a prediction using the structured interface

        It uses the default function if the model has multiple functions.

        - parameters:
           - input: the input to the prediction as yolo11n_segInput

        - throws: an NSError object that describes the problem

        - returns: the result of the prediction as yolo11n_segOutput
    */
    func prediction(input: yolo11n_segInput) throws -> yolo11n_segOutput {
        try prediction(input: input, options: MLPredictionOptions())
    }

    /**
        Make a prediction using the structured interface

        It uses the default function if the model has multiple functions.

        - parameters:
           - input: the input to the prediction as yolo11n_segInput
           - options: prediction options

        - throws: an NSError object that describes the problem

        - returns: the result of the prediction as yolo11n_segOutput
    */
    func prediction(input: yolo11n_segInput, options: MLPredictionOptions) throws -> yolo11n_segOutput {
        let outFeatures = try model.prediction(from: input, options: options)
        return yolo11n_segOutput(features: outFeatures)
    }

    /**
        Make an asynchronous prediction using the structured interface

        It uses the default function if the model has multiple functions.

        - parameters:
           - input: the input to the prediction as yolo11n_segInput
           - options: prediction options

        - throws: an NSError object that describes the problem

        - returns: the result of the prediction as yolo11n_segOutput
    */
    @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    func prediction(input: yolo11n_segInput, options: MLPredictionOptions = MLPredictionOptions()) async throws -> yolo11n_segOutput {
        let outFeatures = try await model.prediction(from: input, options: options)
        return yolo11n_segOutput(features: outFeatures)
    }

    /**
        Make a prediction using the convenience interface

        It uses the default function if the model has multiple functions.

        - parameters:
            - image: color (kCVPixelFormatType_32BGRA) image buffer, 640 pixels wide by 640 pixels high

        - throws: an NSError object that describes the problem

        - returns: the result of the prediction as yolo11n_segOutput
    */
    func prediction(image: CVPixelBuffer) throws -> yolo11n_segOutput {
        let input_ = yolo11n_segInput(image: image)
        return try prediction(input: input_)
    }

    /**
        Make a batch prediction using the structured interface

        It uses the default function if the model has multiple functions.

        - parameters:
           - inputs: the inputs to the prediction as [yolo11n_segInput]
           - options: prediction options

        - throws: an NSError object that describes the problem

        - returns: the result of the prediction as [yolo11n_segOutput]
    */
    func predictions(inputs: [yolo11n_segInput], options: MLPredictionOptions = MLPredictionOptions()) throws -> [yolo11n_segOutput] {
        let batchIn = MLArrayBatchProvider(array: inputs)
        let batchOut = try model.predictions(from: batchIn, options: options)
        var results : [yolo11n_segOutput] = []
        results.reserveCapacity(inputs.count)
        for i in 0..<batchOut.count {
            let outProvider = batchOut.features(at: i)
            let result =  yolo11n_segOutput(features: outProvider)
            results.append(result)
        }
        return results
    }
}
