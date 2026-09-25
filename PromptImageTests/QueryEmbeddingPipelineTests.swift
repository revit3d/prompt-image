import Foundation
import NaturalLanguage
import Testing
@testable import PromptImage

nonisolated private struct RecordedQueryTranslation: Equatable, Sendable {
    let text: String
    let source: QueryLanguage
    let target: QueryLanguage
}

@MainActor
private final class StubQueryTranslator: QueryTranslating {
    var status: QueryTranslationAvailability = .ready
    var response = "a cat on a sofa"
    var error: QueryTranslationError?
    var suspendTranslation = false
    private(set) var availabilityCalls = 0
    private(set) var requests: [RecordedQueryTranslation] = []
    private(set) var unloadCalls = 0

    private var translationStarted: CheckedContinuation<Void, Never>?
    private var pendingTranslation: CheckedContinuation<String, any Error>?

    func availability() async -> QueryTranslationAvailability {
        availabilityCalls += 1
        return status
    }

    func translate(_ text: String, from source: QueryLanguage, to target: QueryLanguage) async throws -> String {
        requests.append(RecordedQueryTranslation(text: text, source: source, target: target))
        if suspendTranslation {
            return try await withCheckedThrowingContinuation { continuation in
                pendingTranslation = continuation
                translationStarted?.resume()
                translationStarted = nil
            }
        }
        if let error { throw error }
        return response
    }

    func unload() async { unloadCalls += 1 }

    /// Signal the exact suspension point without depending on scheduler timing.
    func waitUntilTranslationIsPending() async {
        if pendingTranslation != nil { return }
        await withCheckedContinuation { translationStarted = $0 }
    }

    func finishTranslation(_ text: String) {
        let continuation = pendingTranslation
        pendingTranslation = nil
        continuation?.resume(returning: text)
    }
}

private actor RecordingQueryTextEncoder: QueryTextEncoding {
    let embedding: CLIPEmbedding
    private(set) var texts: [String] = []
    private(set) var unloadCalls = 0

    init() throws {
        embedding = try CLIPEmbedding(rawValues: [1] + Array(repeating: 0, count: 511), modelID: "query-test")
    }

    func textEmbedding(_ text: String) async throws -> CLIPEmbedding {
        texts.append(text)
        return embedding
    }

    func unload() async { unloadCalls += 1 }
}

@MainActor
struct QueryEmbeddingPipelineTests {
    @Test(arguments: [QueryLanguageChoice.english, .automatic],
          [QueryTranslationAvailability.ready, .modelUnavailable])
    func englishBypassesTranslationAndPreservesOriginal(
        choice: QueryLanguageChoice, status: QueryTranslationAvailability
    ) async throws {
        let translator = StubQueryTranslator()
        translator.status = status
        let encoder = try RecordingQueryTextEncoder()
        let pipeline = QueryEmbeddingPipeline(
            translator: translator, encoder: encoder,
            router: QueryLanguageRouter(detector: { _ in [.english: 0.99] })
        )
        let original = " \nA Cat on a Sofa\t "
        let result = try await pipeline.prepare(original, language: choice)

        #expect(result.originalText == original)
        #expect(result.englishText == "A Cat on a Sofa")
        #expect(result.sourceLanguage == .english)
        #expect(result.embedding == encoder.embedding)
        #expect(translator.availabilityCalls == 0)
        #expect(translator.requests.isEmpty)
        let encoded = await encoder.texts
        #expect(encoded == ["A Cat on a Sofa"])
    }

    @Test(arguments: [QueryLanguageChoice.russian, .automatic])
    func russianUsesCorrectLanguagePairBeforeEncodingAndPreservesOriginal(choice: QueryLanguageChoice) async throws {
        let translator = StubQueryTranslator()
        translator.suspendTranslation = true
        let encoder = try RecordingQueryTextEncoder()
        let pipeline = QueryEmbeddingPipeline(
            translator: translator, encoder: encoder,
            router: QueryLanguageRouter(detector: { _ in [.russian: 0.99] })
        )
        let original = " \nКошка на диване\t "
        let task = Task { try await pipeline.prepare(original, language: choice) }
        await translator.waitUntilTranslationIsPending()

        #expect(translator.availabilityCalls == 1)
        #expect(translator.requests == [RecordedQueryTranslation(
            text: "Кошка на диване", source: .russian, target: .english
        )])
        let beforeTranslation = await encoder.texts
        #expect(beforeTranslation.isEmpty)

        translator.finishTranslation(" \nA cat on a sofa\t ")
        let result = try await task.value
        #expect(result.originalText == original)
        #expect(result.englishText == "A cat on a sofa")
        #expect(result.sourceLanguage == .russian)
        #expect(result.embedding == encoder.embedding)
        let encoded = await encoder.texts
        #expect(encoded == ["A cat on a sofa"])
    }

    @Test
    func unavailableModelPreventsTranslationAndEncoding() async throws {
        let translator = StubQueryTranslator()
        translator.status = .modelUnavailable
        let encoder = try RecordingQueryTextEncoder()
        let pipeline = QueryEmbeddingPipeline(translator: translator, encoder: encoder)

        await #expect(throws: QueryTranslationError.modelUnavailable) {
            try await pipeline.prepare("кошка на диване", language: .russian)
        }
        #expect(translator.availabilityCalls == 1)
        #expect(translator.requests.isEmpty)
        let encoded = await encoder.texts
        #expect(encoded.isEmpty)
    }

    @Test(arguments: [QueryTranslationError.modelUnavailable, .unsupportedLanguagePair, .invalidTranslation,
                      .inputTooLong, .generationLimit, .inferenceFailed])
    func translationErrorsPropagateWithoutEncoding(error: QueryTranslationError) async throws {
        let translator = StubQueryTranslator()
        translator.error = error
        let encoder = try RecordingQueryTextEncoder()
        let pipeline = QueryEmbeddingPipeline(translator: translator, encoder: encoder)

        await #expect(throws: error) {
            try await pipeline.prepare("кошка на диване", language: .russian)
        }
        #expect(translator.requests.count == 1)
        let encoded = await encoder.texts
        #expect(encoded.isEmpty)
    }

    @Test(arguments: ["", " \n\t ", String(repeating: "a", count: 16_385), String(repeating: "я", count: 8_193)])
    func invalidTranslationNeverStartsEncoding(response: String) async throws {
        let translator = StubQueryTranslator()
        translator.response = response
        let encoder = try RecordingQueryTextEncoder()
        let pipeline = QueryEmbeddingPipeline(translator: translator, encoder: encoder)

        await #expect(throws: QueryTranslationError.invalidTranslation) {
            try await pipeline.prepare("кошка на диване", language: .russian)
        }
        let encoded = await encoder.texts
        #expect(encoded.isEmpty)
    }

    @Test(arguments: [QueryLanguageChoice.russian, .english])
    func oversizedInputIsRejectedBeforeModelWork(language: QueryLanguageChoice) async throws {
        let translator = StubQueryTranslator()
        let encoder = try RecordingQueryTextEncoder()
        let pipeline = QueryEmbeddingPipeline(translator: translator, encoder: encoder)

        await #expect(throws: QueryInputError.tooLong) {
            try await pipeline.prepare(String(repeating: "я", count: 8_193), language: language)
        }
        #expect(translator.availabilityCalls == 0)
        #expect(translator.requests.isEmpty)
        let encoded = await encoder.texts
        #expect(encoded.isEmpty)
    }

    @Test
    func cancellationBeforePreparationDoesNoWork() async throws {
        let translator = StubQueryTranslator()
        let encoder = try RecordingQueryTextEncoder()
        let pipeline = QueryEmbeddingPipeline(translator: translator, encoder: encoder)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pipeline.prepare("кошка на диване", language: .russian)
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(translator.availabilityCalls == 0)
        #expect(translator.requests.isEmpty)
        let encoded = await encoder.texts
        #expect(encoded.isEmpty)
    }

    @Test
    func cancellationWhileTranslationIsPendingNeverStartsEncoding() async throws {
        let translator = StubQueryTranslator()
        translator.suspendTranslation = true
        let encoder = try RecordingQueryTextEncoder()
        let pipeline = QueryEmbeddingPipeline(translator: translator, encoder: encoder)
        let task = Task { try await pipeline.prepare("кошка на диване", language: .russian) }
        await translator.waitUntilTranslationIsPending()

        task.cancel()
        // Inference may finish after cancellation; its stale result must be discarded.
        translator.finishTranslation("a cat on a sofa")
        await #expect(throws: CancellationError.self) { try await task.value }
        let encoded = await encoder.texts
        #expect(encoded.isEmpty)
    }

    @Test
    func unloadIsForwardedToBothModels() async throws {
        let translator = StubQueryTranslator()
        let encoder = try RecordingQueryTextEncoder()
        let pipeline = QueryEmbeddingPipeline(translator: translator, encoder: encoder)
        await pipeline.unload()

        #expect(translator.unloadCalls == 1)
        let unloadCalls = await encoder.unloadCalls
        #expect(unloadCalls == 1)
        #expect(translator.availabilityCalls == 0)
        #expect(translator.requests.isEmpty)
    }
}
