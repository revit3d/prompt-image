import CoreML
import Foundation

nonisolated struct CLIPModelManifest: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let modelID: String
    let embeddingDimension: Int
    let contextLength: Int
    let imageSize: Int
    let embeddingNormalized: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case modelID = "model_id"
        case embeddingDimension = "embedding_dimension"
        case contextLength = "context_length"
        case imageSize = "image_size"
        case embeddingNormalized = "embedding_normalized"
    }
}

nonisolated enum CLIPEncoder: CaseIterable, Sendable {
    case image
    case text
}

nonisolated enum CLIPModelResourceError: Error, Equatable {
    case missingResource(String)
    case unsupportedManifest
}

/// Locates the prepared model pair without loading weights during app startup.
/// The image input is normalized RGB NCHW; both outputs still need L2 normalization.
nonisolated struct CLIPModelResources {
    let manifest: CLIPModelManifest
    let imageEncoderURL: URL
    let textEncoderURL: URL
    let tokenizerURL: URL
    let licenseURL: URL

    init(bundle: Bundle = .main) throws {
        imageEncoderURL = try Self.resource("CLIPImageEncoder", extension: "mlmodelc", in: bundle)
        textEncoderURL = try Self.resource("CLIPTextEncoder", extension: "mlmodelc", in: bundle)
        tokenizerURL = try Self.resource("tokenizer", extension: "json", in: bundle)
        licenseURL = try Self.resource("LICENSE", extension: "txt", in: bundle)
        let manifestURL = try Self.resource("model-manifest", extension: "json", in: bundle)
        manifest = try JSONDecoder().decode(CLIPModelManifest.self, from: Data(contentsOf: manifestURL))

        guard manifest.schemaVersion == 1,
              manifest.modelID == "openai-clip-vit-b32-fp16-v1",
              manifest.embeddingDimension == 512,
              manifest.contextLength == 77,
              manifest.imageSize == 224,
              !manifest.embeddingNormalized else {
            throw CLIPModelResourceError.unsupportedManifest
        }
    }

    /// Loading is explicit so callers can keep it off the UI thread and control memory use.
    func loadEncoder(_ encoder: CLIPEncoder, computeUnits: MLComputeUnits = .all) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let url = encoder == .image ? imageEncoderURL : textEncoderURL
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    private static func resource(_ name: String, extension fileExtension: String, in bundle: Bundle) throws -> URL {
        guard let url = bundle.url(forResource: name, withExtension: fileExtension) else {
            throw CLIPModelResourceError.missingResource("\(name).\(fileExtension)")
        }
        return url
    }
}
