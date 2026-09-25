import Foundation

nonisolated struct TranslationModelManifest: Decodable, Sendable {
    let schemaVersion: Int
    let modelID: String
    let sourceLanguages: [String]
    let targetLanguage: String
    let maximumSourceTokens: Int
    let maximumDecoderTokens: Int
    let vocabularySize: Int
    let hiddenSize: Int
    let eosTokenID: Int32
    let padTokenID: Int32
    let decoderStartTokenID: Int32

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case modelID = "model_id"
        case sourceLanguages = "source_languages"
        case targetLanguage = "target_language"
        case maximumSourceTokens = "max_source_tokens"
        case maximumDecoderTokens = "max_decoder_tokens"
        case vocabularySize = "vocab_size"
        case hiddenSize = "hidden_size"
        case eosTokenID = "eos_token_id"
        case padTokenID = "pad_token_id"
        case decoderStartTokenID = "decoder_start_token_id"
    }
}

/// Versioned, bundled resources. Future source languages must declare a compatible
/// model/tokenizer/generation contract instead of borrowing the current RU model.
nonisolated struct TranslationModelResources: Sendable {
    let manifest: TranslationModelManifest
    let encoderURL: URL
    let decoderURL: URL
    let sourceTokenizerURL: URL
    let targetTokenizerURL: URL
    let vocabularyURL: URL
    let licenseURL: URL
    let attributionURL: URL

    init(bundle: Bundle = .main) throws {
        try self.init { name, fileExtension in
            guard let url = bundle.url(forResource: name, withExtension: fileExtension) else {
                throw QueryTranslationError.modelUnavailable
            }
            return url
        }
    }

    init(directory: URL) throws {
        try self.init { name, fileExtension in
            let url = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw QueryTranslationError.modelUnavailable
            }
            return url
        }
    }

    private init(resolve: (String, String) throws -> URL) throws {
        encoderURL = try resolve("TranslationEncoder", "mlmodelc")
        decoderURL = try resolve("TranslationDecoder", "mlmodelc")
        sourceTokenizerURL = try resolve("source", "spm")
        targetTokenizerURL = try resolve("target", "spm")
        vocabularyURL = try resolve("vocab", "json")
        licenseURL = try resolve("Translation-LICENSE", "txt")
        attributionURL = try resolve("Translation-ATTRIBUTION", "txt")
        manifest = try JSONDecoder().decode(
            TranslationModelManifest.self,
            from: Data(contentsOf: resolve("translation-manifest", "json"))
        )
        guard manifest.schemaVersion == 1,
              manifest.modelID == "helsinki-opus-mt-ru-en-fp16-v1",
              manifest.sourceLanguages == ["ru"], manifest.targetLanguage == "en",
              manifest.maximumSourceTokens == 64, manifest.maximumDecoderTokens == 64,
              manifest.hiddenSize == 512, manifest.vocabularySize == 62518,
              manifest.eosTokenID == 0, manifest.padTokenID == 62517,
              manifest.decoderStartTokenID == 62517 else {
            throw QueryTranslationError.modelUnavailable
        }
    }
}
