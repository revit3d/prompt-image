import Foundation
import Testing
@testable import PromptImage

@MainActor
private final class DeferredStoreTranslator: QueryTranslating {
    var status: QueryTranslationAvailability = .modelUnavailable
    var deferAvailability = false
    var deferTranslation = false
    var translationError: QueryTranslationError?
    var response = "a cat on a sofa"
    private(set) var availabilityCalls = 0
    private(set) var translationCalls = 0
    private(set) var unloadCalls = 0
    private var pendingAvailability: [Int: CheckedContinuation<QueryTranslationAvailability, Never>] = [:]
    private var pendingTranslation: [Int: CheckedContinuation<String, any Error>] = [:]
    private var availabilityWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var translationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func availability() async -> QueryTranslationAvailability {
        availabilityCalls += 1
        let call = availabilityCalls
        if deferAvailability {
            return await withCheckedContinuation { continuation in
                pendingAvailability[call] = continuation
                resumeAvailabilityWaiters()
            }
        }
        resumeAvailabilityWaiters()
        return status
    }

    func translate(_ text: String, from: QueryLanguage, to: QueryLanguage) async throws -> String {
        translationCalls += 1
        let call = translationCalls
        if deferTranslation {
            return try await withCheckedThrowingContinuation { continuation in
                pendingTranslation[call] = continuation
                resumeTranslationWaiters()
            }
        }
        resumeTranslationWaiters()
        if let translationError { throw translationError }
        return response
    }

    func unload() async { unloadCalls += 1 }

    func waitForAvailabilityCalls(_ count: Int) async {
        if availabilityCalls >= count { return }
        await withCheckedContinuation { availabilityWaiters.append((count, $0)) }
    }

    func waitForTranslationCalls(_ count: Int) async {
        if translationCalls >= count { return }
        await withCheckedContinuation { translationWaiters.append((count, $0)) }
    }

    func finishAvailability(_ call: Int, with status: QueryTranslationAvailability) {
        pendingAvailability.removeValue(forKey: call)?.resume(returning: status)
    }

    func finishTranslation(_ call: Int, with result: Result<String, QueryTranslationError>) {
        guard let continuation = pendingTranslation.removeValue(forKey: call) else { return }
        switch result {
        case .success(let text): continuation.resume(returning: text)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    private func resumeAvailabilityWaiters() {
        let ready = availabilityWaiters.filter { $0.0 <= availabilityCalls }
        availabilityWaiters.removeAll { $0.0 <= availabilityCalls }
        for (_, waiter) in ready { waiter.resume() }
    }

    private func resumeTranslationWaiters() {
        let ready = translationWaiters.filter { $0.0 <= translationCalls }
        translationWaiters.removeAll { $0.0 <= translationCalls }
        for (_, waiter) in ready { waiter.resume() }
    }
}

private actor StoreRecordingEncoder: QueryTextEncoding {
    let embedding: CLIPEmbedding
    private(set) var texts: [String] = []
    private(set) var unloadCalls = 0

    init() throws {
        embedding = try CLIPEmbedding(rawValues: [1] + Array(repeating: 0, count: 511), modelID: "store-test")
    }

    func textEmbedding(_ text: String) async throws -> CLIPEmbedding {
        texts.append(text)
        return embedding
    }

    func unload() async { unloadCalls += 1 }
}

@MainActor
struct QuerySetupStoreTests {
    @Test
    func checkingAvailabilityDoesNotRunTranslationOrEncoding() async throws {
        let translator = DeferredStoreTranslator()
        translator.status = .ready
        let encoder = try StoreRecordingEncoder()
        let store = QuerySetupStore(translator: translator, encoder: encoder)
        #expect(store.availability == nil)
        #expect(translator.availabilityCalls == 0)
        await store.refreshAvailability()

        #expect(store.availability == .ready)
        #expect(!store.isChecking)
        #expect(translator.availabilityCalls == 1)
        #expect(translator.translationCalls == 0)
        let encoded = await encoder.texts
        #expect(encoded.isEmpty)
    }

    @Test(arguments: [false, true])
    func staleQueriesCannotReplaceNewResultAfterClearOrDeactivate(deactivate: Bool) async throws {
        let translator = DeferredStoreTranslator()
        translator.status = .ready
        translator.deferTranslation = true
        let store = QuerySetupStore(translator: translator, encoder: try StoreRecordingEncoder())
        let oldTask = Task { await store.prepareQuery("старое описание", language: .russian) }
        await translator.waitForTranslationCalls(1)
        #expect(store.isProcessing)
        if deactivate { store.deactivate() } else { store.clearQuery() }
        #expect(!store.isProcessing)
        #expect(store.result == nil)
        await store.prepareQuery("a new photo", language: .english)

        translator.finishTranslation(1, with: .success("an old photo"))
        await oldTask.value
        #expect(store.result?.originalText == "a new photo")
        #expect(store.result?.englishText == "a new photo")
        #expect(store.queryMessage == nil)
        #expect(!store.isProcessing)
    }

    @Test
    func staleQueryFailureCannotStopNewQueryOrShowError() async throws {
        let translator = DeferredStoreTranslator()
        translator.status = .ready
        translator.deferTranslation = true
        let store = QuerySetupStore(translator: translator, encoder: try StoreRecordingEncoder())
        let oldTask = Task { await store.prepareQuery("старое описание", language: .russian) }
        await translator.waitForTranslationCalls(1)
        store.clearQuery()
        let newTask = Task { await store.prepareQuery("новое описание", language: .russian) }
        await translator.waitForTranslationCalls(2)

        translator.finishTranslation(1, with: .failure(.modelUnavailable))
        await oldTask.value
        #expect(store.isProcessing)
        #expect(store.result == nil)
        #expect(store.queryMessage == nil)
        #expect(store.availability == nil)
        translator.finishTranslation(2, with: .success("a new photo"))
        await newTask.value
        #expect(store.result?.originalText == "новое описание")
        #expect(!store.isProcessing)
    }

    @Test(arguments: [false, true])
    func oldAvailabilityCannotReplaceNewStatusAfterDeactivation(oldFinishesFirst: Bool) async throws {
        let translator = DeferredStoreTranslator()
        translator.deferAvailability = true
        let store = QuerySetupStore(translator: translator, encoder: try StoreRecordingEncoder())
        let oldTask = Task { await store.refreshAvailability() }
        await translator.waitForAvailabilityCalls(1)
        store.deactivate()
        let newTask = Task { await store.refreshAvailability() }
        await translator.waitForAvailabilityCalls(2)
        if oldFinishesFirst {
            translator.finishAvailability(1, with: .modelUnavailable)
            await oldTask.value
            #expect(store.isChecking)
            #expect(store.availability == nil)
            translator.finishAvailability(2, with: .ready)
            await newTask.value
        } else {
            translator.finishAvailability(2, with: .ready)
            await newTask.value
            translator.finishAvailability(1, with: .modelUnavailable)
            await oldTask.value
        }
        #expect(store.availability == .ready)
        #expect(!store.isChecking)
    }

    @Test
    func olderRefreshCannotOverwriteUnavailableModelReportedByQuery() async throws {
        let translator = DeferredStoreTranslator()
        translator.deferAvailability = true
        translator.translationError = .modelUnavailable
        let store = QuerySetupStore(translator: translator, encoder: try StoreRecordingEncoder())
        let refresh = Task { await store.refreshAvailability() }
        await translator.waitForAvailabilityCalls(1)
        let query = Task { await store.prepareQuery("кошка на диване", language: .russian) }
        await translator.waitForAvailabilityCalls(2)
        translator.finishAvailability(2, with: .ready)
        await query.value
        #expect(store.availability == .modelUnavailable)
        #expect(store.queryMessage != nil)
        translator.finishAvailability(1, with: .ready)
        await refresh.value

        #expect(store.availability == .modelUnavailable)
        #expect(!store.isChecking)
    }

    @Test
    func cancelledRefreshDoesNotReplaceLastKnownAvailability() async throws {
        let translator = DeferredStoreTranslator()
        translator.status = .ready
        let store = QuerySetupStore(translator: translator, encoder: try StoreRecordingEncoder())
        await store.refreshAvailability()
        translator.deferAvailability = true
        let refresh = Task { await store.refreshAvailability() }
        await translator.waitForAvailabilityCalls(2)
        refresh.cancel()
        translator.finishAvailability(2, with: .modelUnavailable)
        await refresh.value

        #expect(store.availability == .ready)
        #expect(!store.isChecking)
    }

    @Test
    func englishWorksWithoutTranslationModel() async throws {
        let translator = DeferredStoreTranslator()
        let encoder = try StoreRecordingEncoder()
        let store = QuerySetupStore(translator: translator, encoder: encoder)
        await store.refreshAvailability()
        await store.prepareQuery(" \na photo of a cat\t", language: .english)

        #expect(store.availability == .modelUnavailable)
        #expect(store.result?.originalText == " \na photo of a cat\t")
        #expect(store.result?.englishText == "a photo of a cat")
        #expect(store.queryMessage == nil)
        #expect(!store.isProcessing)
        #expect(translator.availabilityCalls == 1)
        #expect(translator.translationCalls == 0)
        let encoded = await encoder.texts
        #expect(encoded == ["a photo of a cat"])
    }

    @Test
    func russianWithoutModelReportsFailureWithoutEncoding() async throws {
        let translator = DeferredStoreTranslator()
        let encoder = try StoreRecordingEncoder()
        let store = QuerySetupStore(translator: translator, encoder: encoder)
        await store.prepareQuery("кошка на диване", language: .russian)

        #expect(store.availability == .modelUnavailable)
        #expect(store.result == nil)
        #expect(store.queryMessage != nil)
        #expect(!store.isProcessing)
        #expect(translator.translationCalls == 0)
        let encoded = await encoder.texts
        #expect(encoded.isEmpty)
    }

    @Test(arguments: [QueryTranslationError.unsupportedLanguagePair, .invalidTranslation,
                      .inputTooLong, .generationLimit, .inferenceFailed])
    func failedQueryCanBeRetriedWithoutStaleError(error: QueryTranslationError) async throws {
        let translator = DeferredStoreTranslator()
        translator.status = .ready
        translator.translationError = error
        let encoder = try StoreRecordingEncoder()
        let store = QuerySetupStore(translator: translator, encoder: encoder)
        await store.prepareQuery("кошка на диване", language: .russian)
        #expect(store.result == nil)
        #expect(store.queryMessage != nil)
        #expect(!store.isProcessing)
        let beforeRetry = await encoder.texts
        #expect(beforeRetry.isEmpty)

        translator.translationError = nil
        await store.prepareQuery("кошка на диване", language: .russian)
        #expect(store.result?.englishText == "a cat on a sofa")
        #expect(store.queryMessage == nil)
        #expect(!store.isProcessing)
        let encoded = await encoder.texts
        #expect(encoded == ["a cat on a sofa"])
    }

    @Test
    func preCancelledQueryDoesNotLeaveBusyStateOrError() async throws {
        let translator = DeferredStoreTranslator()
        let encoder = try StoreRecordingEncoder()
        let store = QuerySetupStore(translator: translator, encoder: encoder)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.prepareQuery("a photo of a cat", language: .english)
        }
        await task.value
        #expect(!store.isProcessing)
        #expect(store.result == nil)
        #expect(store.queryMessage == nil)
        let encoded = await encoder.texts
        #expect(encoded.isEmpty)
    }

    @Test
    func preCancelledOldCallsCannotEraseCurrentResultOrSupersedeActiveRefresh() async throws {
        let translator = DeferredStoreTranslator()
        let store = QuerySetupStore(translator: translator, encoder: try StoreRecordingEncoder())
        await store.prepareQuery("the current photo", language: .english)
        translator.deferAvailability = true
        let refresh = Task { await store.refreshAvailability() }
        await translator.waitForAvailabilityCalls(1)
        // Only the existing refresh remains suspended. Any unexpected old call
        // returns immediately, making this regression fail rather than hang.
        translator.deferAvailability = false
        let stale = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.prepareQuery("an obsolete photo", language: .english)
            await store.refreshAvailability()
        }
        await stale.value
        #expect(store.result?.originalText == "the current photo")
        #expect(store.isChecking)
        #expect(translator.availabilityCalls == 1)
        translator.finishAvailability(1, with: .ready)
        await refresh.value

        #expect(store.availability == .ready)
        #expect(!store.isChecking)
        #expect(store.result?.originalText == "the current photo")
        #expect(store.queryMessage == nil)
    }

    @Test
    func cancelledTranslationDoesNotEncodeOrPublishResult() async throws {
        let translator = DeferredStoreTranslator()
        translator.status = .ready
        translator.deferTranslation = true
        let encoder = try StoreRecordingEncoder()
        let store = QuerySetupStore(translator: translator, encoder: encoder)
        let task = Task { await store.prepareQuery("отменённое описание", language: .russian) }
        await translator.waitForTranslationCalls(1)
        task.cancel()
        translator.finishTranslation(1, with: .success("a cancelled translation"))
        await task.value

        #expect(store.result == nil)
        #expect(store.queryMessage == nil)
        #expect(!store.isProcessing)
        let encoded = await encoder.texts
        #expect(encoded.isEmpty)
    }

    @Test
    func unloadReleasesTranslationAndEmbeddingModels() async throws {
        let translator = DeferredStoreTranslator()
        let encoder = try StoreRecordingEncoder()
        let store = QuerySetupStore(translator: translator, encoder: encoder)
        await store.unload()

        #expect(translator.unloadCalls == 1)
        let unloadCalls = await encoder.unloadCalls
        #expect(unloadCalls == 1)
        #expect(translator.availabilityCalls == 0)
        #expect(translator.translationCalls == 0)
    }
}
