import Foundation

nonisolated enum QueryTranslationAvailability: String, Sendable {
    case ready
    case modelUnavailable
}

nonisolated enum QueryTranslationError: Error, Equatable {
    case modelUnavailable
    case unsupportedLanguagePair
    case invalidTranslation
    case inputTooLong
    case generationLimit
    case inferenceFailed
}

@MainActor
protocol QueryTranslating: AnyObject {
    func availability() async -> QueryTranslationAvailability
    /// Uses the versioned translator bundled with the app; never downloads resources.
    func translate(_ text: String, from source: QueryLanguage, to target: QueryLanguage) async throws -> String
    func unload() async
}

nonisolated protocol QueryTextEncoding: Sendable {
    func textEmbedding(_ text: String) async throws -> CLIPEmbedding
    func unload() async
}

extension CLIPEmbeddingEngine: QueryTextEncoding {}

/// Avoid loading CLIP until the first valid query has finished translation.
actor LazyQueryTextEncoder: QueryTextEncoding {
    private var engine: CLIPEmbeddingEngine?

    func textEmbedding(_ text: String) async throws -> CLIPEmbedding {
        try Task.checkCancellation()
        if engine == nil { engine = CLIPEmbeddingEngine(resources: try CLIPModelResources()) }
        guard let engine else { throw CLIPEmbeddingError.invalidModelOutput }
        return try await engine.textEmbedding(text)
    }

    func unload() async {
        let previous = engine
        engine = nil
        await previous?.unload()
    }
}

nonisolated struct PreparedQuery: Sendable {
    /// Kept unchanged for the later OCR search stage, and never persisted/logged here.
    let originalText: String
    let englishText: String
    let sourceLanguage: QueryLanguage
    let embedding: CLIPEmbedding
}

@MainActor
final class QueryEmbeddingPipeline {
    private let translator: any QueryTranslating
    private let encoder: any QueryTextEncoding
    private let router: QueryLanguageRouter

    init(translator: any QueryTranslating, encoder: any QueryTextEncoding = LazyQueryTextEncoder(),
         router: QueryLanguageRouter = QueryLanguageRouter()) {
        self.translator = translator
        self.encoder = encoder
        self.router = router
    }

    func prepare(_ text: String, language: QueryLanguageChoice = .automatic) async throws -> PreparedQuery {
        try Task.checkCancellation()
        let route = try router.route(text, choice: language)
        let englishText: String
        switch route.language {
        case .english:
            englishText = route.text
        case .russian:
            switch await translator.availability() {
            case .ready: break
            case .modelUnavailable: throw QueryTranslationError.modelUnavailable
            }
            try Task.checkCancellation()
            englishText = try await translator.translate(route.text, from: route.language, to: .english)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !englishText.isEmpty, englishText.utf8.count <= 16_384 else {
                throw QueryTranslationError.invalidTranslation
            }
        }
        try Task.checkCancellation()
        let embedding = try await encoder.textEmbedding(englishText)
        try Task.checkCancellation()
        return PreparedQuery(originalText: route.originalText, englishText: englishText,
                             sourceLanguage: route.language, embedding: embedding)
    }

    func unload() async {
        await translator.unload()
        await encoder.unload()
    }
}
