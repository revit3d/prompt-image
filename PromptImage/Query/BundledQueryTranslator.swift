import CoreML
import Foundation

@MainActor
final class BundledQueryTranslator: QueryTranslating {
    private let engine: BundledTranslationEngine

    init(engine: BundledTranslationEngine = BundledTranslationEngine()) {
        self.engine = engine
    }

    func availability() async -> QueryTranslationAvailability {
        await engine.availability()
    }

    func translate(_ text: String, from source: QueryLanguage, to target: QueryLanguage) async throws -> String {
        try await engine.translate(text, from: source.rawValue, to: target.rawValue)
    }

    func unload() async { await engine.unload() }
}

/// Serial generation using bundled Core ML weights and the official SentencePiece
/// runtime. No Apple Translation, network requests, query logs, or disk writes.
actor BundledTranslationEngine {
    private var resources: TranslationModelResources?
    private let computeUnits: MLComputeUnits
    private var tokenizer: MarianTokenizer?
    private var encoder: MLModel?
    private var decoder: MLModel?

    init(resources: TranslationModelResources? = nil, computeUnits: MLComputeUnits = .all) {
        self.resources = resources
        self.computeUnits = computeUnits
    }

    func availability() -> QueryTranslationAvailability {
        do {
            _ = try resolveResources()
            return .ready
        } catch {
            return .modelUnavailable
        }
    }

    func translate(_ text: String, from source: String, to target: String) throws -> String {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QueryTranslationError.invalidTranslation
        }
        guard text.utf8.prefix(16_385).count <= 16_384 else { throw QueryTranslationError.inputTooLong }
        let resources = try resolveResources()
        let manifest = resources.manifest
        guard manifest.sourceLanguages.contains(source), manifest.targetLanguage == target else {
            throw QueryTranslationError.unsupportedLanguagePair
        }
        do {
            return try autoreleasepool {
                if tokenizer == nil {
                    tokenizer = try MarianTokenizer(sourceModelURL: resources.sourceTokenizerURL,
                        targetModelURL: resources.targetTokenizerURL, vocabularyURL: resources.vocabularyURL)
                }
                guard let tokenizer else { throw QueryTranslationError.modelUnavailable }
                let ids = try tokenizer.encode(text)
                guard !ids.isEmpty, ids.last == manifest.eosTokenID,
                      ids.allSatisfy({ $0 >= 0 && Int($0) < manifest.vocabularySize }) else {
                    throw QueryTranslationError.invalidTranslation
                }
                guard ids.count <= manifest.maximumSourceTokens else { throw QueryTranslationError.inputTooLong }
                try Task.checkCancellation()
                let sourceTokens = try Self.tokens(ids, length: manifest.maximumSourceTokens, padding: manifest.padTokenID)
                let sourceMask = try Self.mask(active: ids.count, length: manifest.maximumSourceTokens)
                if encoder == nil { encoder = try loadModel(resources.encoderURL) }
                if decoder == nil { decoder = try loadModel(resources.decoderURL) }
                guard let encoder, let decoder else { throw QueryTranslationError.modelUnavailable }
                try Task.checkCancellation()
                let encoded = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "source_tokens": MLFeatureValue(multiArray: sourceTokens),
                    "source_mask": MLFeatureValue(multiArray: sourceMask),
                ]))
                guard let hidden = encoded.featureValue(for: "source_hidden")?.multiArrayValue,
                      hidden.shape.map(\.intValue) == [1, manifest.maximumSourceTokens, manifest.hiddenSize],
                      hidden.dataType == .float32 else { throw QueryTranslationError.inferenceFailed }
                var prefix = [manifest.decoderStartTokenID]
                var generated: [Int32] = []
                while prefix.count < manifest.maximumDecoderTokens {
                    try Task.checkCancellation()
                    let next: Int32 = try autoreleasepool {
                        let decoderTokens = try Self.tokens(prefix, length: manifest.maximumDecoderTokens, padding: manifest.padTokenID)
                        let decoderMask = try Self.mask(active: prefix.count, length: manifest.maximumDecoderTokens)
                        let position = try MLMultiArray(shape: [1], dataType: .int32)
                        position[0] = NSNumber(value: prefix.count - 1)
                        let prediction = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                            "decoder_tokens": MLFeatureValue(multiArray: decoderTokens),
                            "decoder_mask": MLFeatureValue(multiArray: decoderMask),
                            "source_hidden": MLFeatureValue(multiArray: hidden),
                            "source_mask": MLFeatureValue(multiArray: sourceMask),
                            "last_index": MLFeatureValue(multiArray: position),
                        ]))
                        guard let logits = prediction.featureValue(for: "logits")?.multiArrayValue,
                              logits.shape.map(\.intValue) == [1, manifest.vocabularySize],
                              logits.dataType == .float32 else { throw QueryTranslationError.inferenceFailed }
                        return try Self.argmax(logits, excluding: manifest.padTokenID)
                    }
                    try Task.checkCancellation()
                    if next == manifest.eosTokenID {
                        let translation = try tokenizer.decode(generated).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !translation.isEmpty, translation.utf8.count <= 16_384 else {
                            throw QueryTranslationError.invalidTranslation
                        }
                        return translation
                    }
                    generated.append(next)
                    prefix.append(next)
                }
                // Never return an unfinished sentence as a successful translation.
                throw QueryTranslationError.generationLimit
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? QueryTranslationError { throw error }
            if let error = error as? MarianTokenizerError {
                switch error {
                case .inputTooLong, .tooManyTokens: throw QueryTranslationError.inputTooLong
                case .invalidResources: throw QueryTranslationError.modelUnavailable
                case .encodingFailed, .decodingFailed: throw QueryTranslationError.invalidTranslation
                }
            }
            throw QueryTranslationError.inferenceFailed
        }
    }

    func unload() {
        tokenizer = nil
        encoder = nil
        decoder = nil
    }

    private func resolveResources() throws -> TranslationModelResources {
        if let resources { return resources }
        do {
            let loaded = try TranslationModelResources()
            resources = loaded
            return loaded
        } catch {
            throw QueryTranslationError.modelUnavailable
        }
    }

    private func loadModel(_ url: URL) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    private static func tokens(_ values: [Int32], length: Int, padding: Int32) throws -> MLMultiArray {
        let tensor = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let pointer = tensor.dataPointer.assumingMemoryBound(to: Int32.self)
        for index in 0..<length { pointer[index] = index < values.count ? values[index] : padding }
        return tensor
    }

    private static func mask(active: Int, length: Int) throws -> MLMultiArray {
        try tokens(Array(repeating: 1, count: active), length: length, padding: 0)
    }

    private static func argmax(_ logits: MLMultiArray, excluding bannedID: Int32) throws -> Int32 {
        var bestID: Int32 = -1
        var bestValue = -Float.infinity
        // Standard contiguous Core ML output is the fast path; preserve strides
        // if a future runtime returns a different layout.
        let stride = logits.strides.last?.intValue ?? 1
        let pointer = logits.dataPointer.assumingMemoryBound(to: Float.self)
        for index in 0..<logits.count where index != Int(bannedID) {
            let value = pointer[index * stride]
            guard value.isFinite else { throw QueryTranslationError.inferenceFailed }
            if value > bestValue {
                bestValue = value
                bestID = Int32(index)
            }
        }
        guard bestID >= 0 else { throw QueryTranslationError.inferenceFailed }
        return bestID
    }
}
