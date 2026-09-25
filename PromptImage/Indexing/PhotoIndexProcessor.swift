import Foundation

nonisolated protocol PhotoIndexProcessing: Sendable {
    func versions() async throws -> PhotoIndexVersions
    func embedding(_ source: PhotoOCRSource) async throws -> CLIPEmbedding
    func recognize(_ source: PhotoOCRSource) async throws -> PhotoOCRResult
    func unload() async
}

/// Shares the existing image and OCR contracts; no translation model is needed
/// while building the library index. All model preparation happens off the UI actor.
actor PhotoIndexProcessor: PhotoIndexProcessing {
    private var resources: CLIPModelResources?
    private var clip: CLIPEmbeddingEngine?

    func versions() throws -> PhotoIndexVersions {
        let resources = try loadResources()
        return PhotoIndexVersions(embedding: resources.manifest.modelID, ocr: PhotoIndexPipeline.currentOCRVersion)
    }

    func embedding(_ source: PhotoOCRSource) async throws -> CLIPEmbedding {
        try Task.checkCancellation()
        if clip == nil { clip = try CLIPEmbeddingEngine(resources: loadResources()) }
        guard let clip else { throw CLIPEmbeddingError.invalidModelOutput }
        return try await clip.imageEmbedding(data: source.data, orientation: source.orientation)
    }

    func recognize(_ source: PhotoOCRSource) async throws -> PhotoOCRResult {
        try await PhotoOCREngine.shared.recognize(source)
    }

    func unload() async {
        await clip?.unload()
        clip = nil
    }

    private func loadResources() throws -> CLIPModelResources {
        if let resources { return resources }
        let loaded = try CLIPModelResources()
        resources = loaded
        return loaded
    }
}
