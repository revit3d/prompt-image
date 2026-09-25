import CoreML
import Foundation
import ImageIO

/// Serial, off-main-actor preprocessing and inference. No PhotoKit, network, or disk writes.
/// Models load only on demand and can be released when indexing/search is idle.
actor CLIPEmbeddingEngine {
    private let resources: CLIPModelResources
    private let computeUnits: MLComputeUnits
    private var imageModel: MLModel?
    private var textModel: MLModel?
    private var tokenizer: CLIPTokenizer?

    init(resources: CLIPModelResources, computeUnits: MLComputeUnits = .all) {
        self.resources = resources
        self.computeUnits = computeUnits
    }

    func imageEmbedding(data: Data, orientation: CGImagePropertyOrientation? = nil) throws -> CLIPEmbedding {
        try Task.checkCancellation()
        return try autoreleasepool {
            let input = try CLIPImagePreprocessor().prepare(data: data, orientation: orientation)
            try Task.checkCancellation()
            if imageModel == nil { imageModel = try resources.loadEncoder(.image, computeUnits: computeUnits) }
            guard let imageModel else { throw CLIPEmbeddingError.invalidModelOutput }
            return try predict(model: imageModel, name: "image", input: input)
        }
    }

    /// CLIP's English baseline. Russian translation is introduced separately in step 3.3.
    func textEmbedding(_ text: String) throws -> CLIPEmbedding {
        try Task.checkCancellation()
        return try autoreleasepool {
            if tokenizer == nil { tokenizer = try CLIPTokenizer(contentsOf: resources.tokenizerURL) }
            guard let tokenizer else { throw CLIPEmbeddingError.invalidModelOutput }
            let tokens = try tokenizer.encode(text)
            let input = try MLMultiArray(shape: [1, 77], dataType: .int32)
            for (index, token) in tokens.enumerated() { input[index] = NSNumber(value: token) }
            try Task.checkCancellation()
            if textModel == nil { textModel = try resources.loadEncoder(.text, computeUnits: computeUnits) }
            guard let textModel else { throw CLIPEmbeddingError.invalidModelOutput }
            return try predict(model: textModel, name: "tokens", input: input)
        }
    }

    func unload() {
        imageModel = nil
        textModel = nil
        tokenizer = nil
    }

    private func predict(model: MLModel, name: String, input: MLMultiArray) throws -> CLIPEmbedding {
        try Task.checkCancellation()
        let features = try MLDictionaryFeatureProvider(dictionary: [name: MLFeatureValue(multiArray: input)])
        let prediction = try model.prediction(from: features)
        // A running synchronous Core ML call finishes before cancellation is observed.
        try Task.checkCancellation()
        guard let output = prediction.featureValue(for: "embedding")?.multiArrayValue,
              output.shape.map(\.intValue) == [1, 512], output.dataType == .float32 else {
            throw CLIPEmbeddingError.invalidModelOutput
        }
        return try CLIPEmbedding(
            rawValues: (0..<512).map { output[$0].floatValue },
            modelID: resources.manifest.modelID
        )
    }
}
