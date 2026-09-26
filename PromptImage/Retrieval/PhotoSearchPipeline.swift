import Foundation

nonisolated enum PhotoSearchError: Error, Equatable, LocalizedError {
    case indexNotReady
    case invalidLimit

    var errorDescription: String? {
        switch self {
        case .indexNotReady: "Дождитесь обновления медиатеки перед поиском."
        case .invalidLimit: "Не удалось выполнить поиск с указанным количеством результатов."
        }
    }
}

nonisolated struct PhotoSearchMatch: Sendable, Equatable {
    let photo: LibraryPhoto
    /// Reciprocal-rank fusion score, not confidence or a probability.
    let score: Double
    let visualSimilarity: Float?
    let recognizedText: String?
}

/// Searches the personal library through its existing index owner. Queries and
/// results stay in memory; no photo source requests or new database connections.
@MainActor
final class PhotoSearchPipeline {
    private let queryPipeline: QueryEmbeddingPipeline
    private let index: PhotoIndexingStore

    convenience init(index: PhotoIndexingStore) {
        self.init(queryPipeline: QueryEmbeddingPipeline(translator: BundledQueryTranslator()), index: index)
    }

    init(queryPipeline: QueryEmbeddingPipeline, index: PhotoIndexingStore) {
        self.queryPipeline = queryPipeline
        self.index = index
    }

    func search(_ text: String, language: QueryLanguageChoice = .automatic,
                limit: Int = 50) async throws -> [PhotoSearchMatch] {
        try Task.checkCancellation()
        try Self.validate(text, limit: limit)
        return try await index.search(limit: limit) {
            try await self.queryPipeline.prepare(text, language: language)
        }
    }

    func unload() async { await queryPipeline.unload() }

    nonisolated static func validate(_ text: String, limit: Int) throws {
        guard (1...ReciprocalRankFusion.candidateLimit).contains(limit) else {
            throw PhotoSearchError.invalidLimit
        }
        // Share the OCR parser's bounds; reject before translation/model loading.
        do { _ = try PhotoIndexTextQuery.literal(text) }
        catch PhotoIndexError.invalidInput { throw QueryInputError.tooLong }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QueryInputError.empty
        }
    }
}
