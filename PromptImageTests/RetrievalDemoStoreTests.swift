import Foundation
import Testing
@testable import PromptImage

private actor DeferredRetrievalDemo: RetrievalDemoServing {
    enum Call: Hashable { case load, prepare, search }
    var deferred: Set<Call> = []
    var nextError: RetrievalDemoError?
    private(set) var counts: [Call: Int] = [:]
    private(set) var unloadCalls = 0
    private(set) var searches: [(String, QueryLanguageChoice)] = []
    private var pending: [Call: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [(Call, Int, CheckedContinuation<Void, Never>)] = []
    private var progress: (nonisolated(nonsending) @Sendable (Int, Int) async -> Void)?

    func setDeferred(_ calls: Set<Call>) { deferred = calls }
    func setError(_ error: RetrievalDemoError?) { nextError = error }

    func load() async throws -> RetrievalDemoSummary {
        await called(.load)
        if let nextError { throw nextError }
        return RetrievalDemoSummary(imageCount: 400, queries: [])
    }

    func prepare(progress: nonisolated(nonsending) @escaping @Sendable (Int, Int) async -> Void) async throws {
        self.progress = progress
        await called(.prepare)
        if let nextError { throw nextError }
        await progress(400, 400)
    }

    func search(_ text: String, language: QueryLanguageChoice) async throws -> RetrievalDemoSearchResult {
        searches.append((text, language))
        await called(.search)
        if let nextError { throw nextError }
        return RetrievalDemoSearchResult(originalText: text, englishText: "a cat", matches: [])
    }

    func unload() async { unloadCalls += 1 }

    func reportProgress(_ completed: Int, total: Int = 400) async {
        await progress?(completed, total)
    }

    func finish(_ call: Call) { pending.removeValue(forKey: call)?.resume() }

    func waitFor(_ call: Call, count: Int = 1) async {
        if counts[call, default: 0] >= count { return }
        await withCheckedContinuation { waiters.append((call, count, $0)) }
    }

    private func called(_ call: Call) async {
        counts[call, default: 0] += 1
        if deferred.contains(call) {
            // Intentionally ignore cancellation to model a synchronous prediction
            // already in progress. The store must reject its eventual result.
            await withCheckedContinuation { continuation in
                pending[call] = continuation
                releaseWaiters()
            }
        } else {
            releaseWaiters()
        }
    }

    private func releaseWaiters() {
        let ready = waiters.filter { counts[$0.0, default: 0] >= $0.1 }
        waiters.removeAll { counts[$0.0, default: 0] >= $0.1 }
        for (_, _, continuation) in ready { continuation.resume() }
    }
}

@MainActor
struct RetrievalDemoStoreTests {
    @Test
    func loadDoesNotPrepareOrSearchAndReportsProgressUntilReady() async {
        let engine = DeferredRetrievalDemo()
        let store = RetrievalDemoStore(engine: engine)
        store.activate()
        await store.waitForIdle()
        #expect(store.summary?.imageCount == 400)
        #expect(!store.isPrepared)
        #expect(await engine.counts[.prepare] == nil)
        #expect(await engine.counts[.search] == nil)

        await engine.setDeferred([.prepare])
        store.prepare()
        await engine.waitFor(.prepare)
        await engine.reportProgress(137)
        #expect(store.completedImages == 137)
        #expect(store.totalImages == 400)
        #expect(!store.isPrepared)
        #expect(store.operation == .indexing)
        await engine.finish(.prepare)
        await store.waitForIdle()
        #expect(store.completedImages == 400)
        #expect(store.isPrepared)
        #expect(!store.isWorking)
    }

    @Test
    func cancelledPreparationStaysBusyAndCannotPublishPartialIndex() async {
        let engine = DeferredRetrievalDemo()
        let store = RetrievalDemoStore(engine: engine)
        store.activate()
        await store.waitForIdle()
        await engine.setDeferred([.prepare])
        store.prepare()
        await engine.waitFor(.prepare)
        await engine.reportProgress(150)
        store.cancel()
        #expect(store.isWorking)
        #expect(store.isCancelling)
        #expect(!store.isPrepared)
        store.prepare()
        #expect(await engine.counts[.prepare] == 1)
        await engine.reportProgress(300)
        #expect(store.completedImages == 150)
        await engine.finish(.prepare)
        await store.waitForIdle()
        #expect(!store.isWorking)
        #expect(!store.isPrepared)
        #expect(store.message == nil)

        store.prepare()
        await engine.waitFor(.prepare, count: 2)
        #expect(store.completedImages == 0)
        await engine.finish(.prepare)
        await store.waitForIdle()
        #expect(store.isPrepared)
    }

    @Test(arguments: [false, true])
    func editingDiscardsLateSearchSuccessOrFailure(failure: Bool) async {
        let engine = DeferredRetrievalDemo()
        let store = await preparedStore(engine)
        await engine.setDeferred([.search])
        store.search("старое описание", language: .russian)
        await engine.waitFor(.search)
        store.queryChanged()
        #expect(store.isWorking)
        store.search("new description", language: .english)
        #expect(await engine.counts[.search] == 1)
        if failure { await engine.setError(.imageChanged) }
        await engine.finish(.search)
        await store.waitForIdle()
        #expect(store.result == nil)
        #expect(store.message == nil)
        #expect(store.isPrepared)
        #expect(!store.isWorking)

        await engine.setError(nil)
        await engine.setDeferred([])
        store.search("new description", language: .english)
        await store.waitForIdle()
        #expect(store.result?.originalText == "new description")
        let searches = await engine.searches
        #expect(searches.count == 2)
        #expect(searches.last?.1 == .english)
    }

    @Test
    func inactiveStopsPendingQueryButKeepsCompletedIndex() async {
        let engine = DeferredRetrievalDemo()
        let store = await preparedStore(engine)
        await engine.setDeferred([.search])
        store.search("a cat", language: .english)
        await engine.waitFor(.search)
        store.deactivate()
        store.search("a dog", language: .english)
        await engine.finish(.search)
        await store.waitForIdle()
        #expect(store.result == nil)
        #expect(store.isPrepared)
        #expect(await engine.unloadCalls == 0)

        await engine.setDeferred([])
        store.activate()
        store.search("a dog", language: .english)
        await store.waitForIdle()
        #expect(store.result?.originalText == "a dog")
        #expect(await engine.counts[.load] == 1)
        #expect(await engine.counts[.prepare] == 1)
    }

    @Test
    func returningDuringCancelledLoadRestartsAfterOldLoadExits() async {
        let engine = DeferredRetrievalDemo()
        await engine.setDeferred([.load])
        let store = RetrievalDemoStore(engine: engine)
        store.activate()
        await engine.waitFor(.load)
        store.deactivate()
        store.activate()
        #expect(await engine.counts[.load] == 1)
        await engine.finish(.load)
        await engine.waitFor(.load, count: 2)
        #expect(store.summary == nil)
        #expect(store.isWorking)
        await engine.finish(.load)
        await store.waitForIdle()
        #expect(store.summary?.imageCount == 400)
    }

    @Test
    func missingCorpusCanBeRetriedWithoutPreparingImages() async {
        let engine = DeferredRetrievalDemo()
        await engine.setError(.corpusMissing)
        let store = RetrievalDemoStore(engine: engine)
        store.activate()
        await store.waitForIdle()
        #expect(store.summary == nil)
        #expect(store.message != nil)
        #expect(!store.isWorking)
        await engine.setError(nil)
        store.load()
        await store.waitForIdle()
        #expect(store.summary?.imageCount == 400)
        #expect(store.message == nil)
        #expect(await engine.counts[.prepare] == nil)
    }

    @Test
    func preparationFailureNeverEnablesSearchAndCanRetry() async {
        let engine = DeferredRetrievalDemo()
        let store = RetrievalDemoStore(engine: engine)
        store.activate()
        await store.waitForIdle()
        await engine.setError(.imageChanged)
        store.prepare()
        await store.waitForIdle()
        #expect(!store.isPrepared)
        #expect(store.message != nil)
        store.search("a cat", language: .english)
        #expect(await engine.counts[.search] == nil)
        await engine.setError(nil)
        store.prepare()
        await store.waitForIdle()
        #expect(store.isPrepared)
        #expect(store.message == nil)
    }

    @Test(arguments: [RetrievalDemoError.indexNotReady, .imageChanged, .invalidCorpus])
    func invalidatedIndexRequiresPreparationBeforeRetry(error: RetrievalDemoError) async {
        let engine = DeferredRetrievalDemo()
        let store = await preparedStore(engine)
        await engine.setError(error)
        store.search("a cat", language: .english)
        await store.waitForIdle()
        #expect(!store.isPrepared)
        #expect(store.result == nil)
        #expect(store.message == error.errorDescription)
        store.search("a cat", language: .english)
        #expect(await engine.counts[.search] == 1)

        await engine.setError(nil)
        store.prepare()
        await store.waitForIdle()
        #expect(store.isPrepared)
        #expect(store.message == nil)
        store.search("a cat", language: .english)
        await store.waitForIdle()
        #expect(store.result?.originalText == "a cat")
        #expect(await engine.counts[.search] == 2)
    }

    @Test
    func closeWaitsForCancelledWorkBeforeUnloadAndPreventsReactivation() async {
        let engine = DeferredRetrievalDemo()
        let store = await preparedStore(engine)
        await engine.setDeferred([.search])
        store.search("a cat", language: .english)
        await engine.waitFor(.search)
        store.close()
        store.activate()
        #expect(store.operation == .closing)
        #expect(await engine.unloadCalls == 0)
        #expect(!store.isPrepared)
        await engine.finish(.search)
        await store.waitForIdle()
        #expect(await engine.unloadCalls == 1)
        #expect(store.result == nil)
        #expect(!store.isWorking)
        store.load()
        store.prepare()
        store.search("a dog", language: .english)
        store.close()
        await store.waitForIdle()
        #expect(await engine.counts[.load] == 1)
        #expect(await engine.counts[.prepare] == 1)
        #expect(await engine.counts[.search] == 1)
        #expect(await engine.unloadCalls == 1)
    }

    private func preparedStore(_ engine: DeferredRetrievalDemo) async -> RetrievalDemoStore {
        let store = RetrievalDemoStore(engine: engine)
        store.activate()
        await store.waitForIdle()
        store.prepare()
        await store.waitForIdle()
        return store
    }
}
