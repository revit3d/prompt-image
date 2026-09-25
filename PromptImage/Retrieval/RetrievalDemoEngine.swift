import CoreML
import Foundation

nonisolated protocol RetrievalDemoServing: Sendable {
    func load() async throws -> RetrievalDemoSummary
    func prepare(progress: @escaping @Sendable (Int, Int) async -> Void) async throws
    func search(_ text: String, language: QueryLanguageChoice) async throws -> RetrievalDemoSearchResult
    func unload() async
}

/// Bounded evaluation-only index. Only normalized vectors and file references
/// survive preparation; original image bytes and the image model are released.
actor RetrievalDemoEngine: RetrievalDemoServing {
    private let directory: URL
    private let computeUnits: MLComputeUnits
    private var corpus: RetrievalDemoCorpus?
    private var index: SemanticImageIndex?
    private var queryPipeline: QueryEmbeddingPipeline?
    private var isPreparing = false
    private var generation = 0

    init(directory: URL = RetrievalDemoCorpus.defaultDirectory, computeUnits: MLComputeUnits = .all) {
        self.directory = directory
        self.computeUnits = computeUnits
    }

    func load() throws -> RetrievalDemoSummary {
        try Task.checkCancellation()
        if let corpus { return corpus.summary }
        let loaded = try RetrievalDemoCorpus(directory: directory)
        // The developer-copied sample is derived test data, not a backup source.
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        corpus = loaded
        return loaded.summary
    }

    func prepare(progress: @escaping @Sendable (Int, Int) async -> Void) async throws {
        try Task.checkCancellation()
        guard !isPreparing else { throw RetrievalDemoError.preparationInProgress }
        generation += 1
        let operation = generation
        isPreparing = true
        defer { isPreparing = false }
        _ = try load()
        guard let corpus else { throw RetrievalDemoError.corpusMissing }
        index = nil
        // Do not retain translation/text models while loading the image encoder.
        await queryPipeline?.unload()
        try check(operation)
        let engine = CLIPEmbeddingEngine(resources: try CLIPModelResources(), computeUnits: computeUnits)
        do {
            var records: [SemanticIndexedImage] = []
            records.reserveCapacity(corpus.images.count)
            await progress(0, corpus.images.count)
            for image in corpus.images {
                try check(operation)
                let embedding = try await engine.imageEmbedding(data: corpus.imageData(for: image))
                try check(operation)
                records.append(.init(id: image.id, embedding: embedding))
                await progress(records.count, corpus.images.count)
            }
            let completed = try SemanticImageIndex(modelID: RetrievalDemoCorpus.modelID, images: records)
            await engine.unload()
            try check(operation)
            index = completed
        } catch {
            await engine.unload()
            throw error
        }
    }

    func search(_ text: String, language: QueryLanguageChoice) async throws -> RetrievalDemoSearchResult {
        try Task.checkCancellation()
        guard !isPreparing, let index, let corpus else { throw RetrievalDemoError.indexNotReady }
        let operation = generation
        if queryPipeline == nil {
            let units = computeUnits
            let resources = try CLIPModelResources()
            queryPipeline = await MainActor.run {
                QueryEmbeddingPipeline(translator: BundledQueryTranslator(engine: BundledTranslationEngine(computeUnits: units)),
                                       encoder: CLIPEmbeddingEngine(resources: resources, computeUnits: units))
            }
        }
        try check(operation)
        guard !isPreparing else { throw CancellationError() }
        guard let queryPipeline else { throw RetrievalDemoError.indexNotReady }
        let prepared = try await queryPipeline.prepare(text, language: language)
        try check(operation)
        guard !isPreparing, self.index != nil else { throw RetrievalDemoError.indexNotReady }
        let ranked = try index.search(query: prepared.embedding, topK: 10)
        let images = Dictionary(uniqueKeysWithValues: corpus.images.map { ($0.id, $0) })
        let matches = try ranked.map { match -> RetrievalDemoMatch in
            guard let record = images[match.id] else { throw RetrievalDemoError.invalidCorpus }
            return .init(id: match.id, imageURL: try corpus.imageURL(for: record), score: match.score)
        }
        return .init(originalText: prepared.originalText, englishText: prepared.englishText, matches: matches)
    }

    func unload() async {
        generation += 1
        index = nil
        corpus = nil
        let previous = queryPipeline
        queryPipeline = nil
        await previous?.unload()
    }

    private func check(_ operation: Int) throws {
        try Task.checkCancellation()
        guard generation == operation else { throw CancellationError() }
    }
}
