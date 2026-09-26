import Foundation
import Testing
@testable import PromptImage

/// The engine deliberately ignores cancellation while held, like an in-flight
/// native prediction. Tests exercise publication and cleanup rather than models.
@MainActor
struct PhotoSearchStoreTests {
    @Test
    func editsDoNotSearchUntilTheUserSubmits() async {
        let fixture = SearchScreenFixture()
        fixture.store.activate()
        fixture.store.text = "рецепт блинов"
        fixture.store.language = .russian
        await fixture.store.waitForIdle()

        #expect(fixture.store.mode == .combined)
        #expect(fixture.engine.requests.isEmpty)
        #expect(fixture.store.matches.isEmpty)

        fixture.store.search()
        await fixture.store.waitForIdle()

        #expect(fixture.engine.requests.count == 1)
        #expect(fixture.engine.requests.first?.text == "рецепт блинов")
        #expect(fixture.engine.requests.first?.language == .russian)
        #expect(fixture.engine.requests.first?.mode == .combined)
        #expect(fixture.engine.requests.first?.limit == 50)
        #expect(fixture.store.phase == .results)
        #expect(fixture.store.matches.map(\.photo.id) == ["рецепт блинов"])
        #expect(fixture.store.message == nil)
        #expect(!fixture.store.isWorking)
    }

    @Test(arguments: ["", " \n\t ", String(repeating: "a", count: 4_097),
                      Array(repeating: "word", count: 33).joined(separator: " ")])
    func invalidInputNeverReachesTheEngine(query: String) async {
        let fixture = SearchScreenFixture()
        fixture.store.activate()
        fixture.store.text = query
        fixture.store.search()
        await fixture.store.waitForIdle()

        #expect(fixture.engine.requests.isEmpty)
        #expect(fixture.store.matches.isEmpty)
        #expect(!fixture.store.isWorking)
    }

    @Test
    func anUnreadyIndexWaitsWithoutLoadingModelsAndAllowsExplicitRetry() async {
        let fixture = SearchScreenFixture()
        fixture.state = PhotoSearchIndexState(isReady: false, summary: searchScreenSummary(), message: nil)
        fixture.store.activate()
        fixture.store.text = "recipe"
        fixture.store.search()
        await fixture.store.waitForIdle()

        #expect(fixture.store.phase == .waitingForIndex)
        #expect(fixture.engine.requests.isEmpty)

        fixture.state = PhotoSearchIndexState(isReady: true, summary: searchScreenSummary(), message: nil)
        await fixture.store.waitForIdle()
        #expect(fixture.engine.requests.isEmpty)
        fixture.store.search()
        await fixture.store.waitForIdle()
        #expect(fixture.store.phase == .results)
        #expect(fixture.engine.requests.count == 1)
    }

    @Test
    func anEmptyIndexIsDifferentFromASearchWithNoMatches() async {
        let fixture = SearchScreenFixture()
        fixture.state = PhotoSearchIndexState(isReady: true, summary: .empty, message: nil)
        fixture.store.activate()
        fixture.store.text = "recipe"
        fixture.store.search()
        await fixture.store.waitForIdle()
        #expect(fixture.store.phase == .emptyIndex)
        #expect(fixture.engine.requests.isEmpty)

        fixture.state = PhotoSearchIndexState(isReady: true, summary: searchScreenSummary(), message: nil)
        fixture.engine.emptyResults = true
        fixture.store.search()
        await fixture.store.waitForIdle()
        #expect(fixture.store.phase == .noMatches)
        #expect(fixture.engine.requests.count == 1)
        #expect(fixture.store.matches.isEmpty)
    }

    @Test(arguments: [PhotoSearchMode.combined, .textOnly])
    func aPartialOCRIndexCanBeSearchedWhileOtherPhotosRemainPending(mode: PhotoSearchMode) async {
        let fixture = SearchScreenFixture()
        fixture.state = PhotoSearchIndexState(isReady: true,
            summary: searchScreenSummary(embeddings: 0, ocr: 1, pending: 9), message: nil)
        fixture.store.activate()
        fixture.store.mode = mode
        fixture.store.text = "рецепт"
        fixture.store.search()
        await fixture.store.waitForIdle()

        #expect(fixture.store.phase == .results)
        #expect(fixture.engine.requests.first?.mode == mode)
    }

    @Test
    func textOnlyRequiresCompletedOCRButCombinedCanUseVisualEmbeddings() async {
        let fixture = SearchScreenFixture()
        fixture.state = PhotoSearchIndexState(isReady: true,
            summary: searchScreenSummary(embeddings: 1, ocr: 0), message: nil)
        fixture.store.activate()
        fixture.store.text = "recipe"
        fixture.store.mode = .textOnly
        fixture.store.search()
        await fixture.store.waitForIdle()
        #expect(fixture.store.phase == .emptyIndex)
        #expect(fixture.engine.requests.isEmpty)

        fixture.store.mode = .combined
        fixture.store.search()
        await fixture.store.waitForIdle()
        #expect(fixture.store.phase == .results)
        #expect(fixture.engine.requests.first?.mode == .combined)
    }

    @Test(arguments: SearchScreenEdit.allCases)
    func editingAnyQueryInputImmediatelyClearsResultsAndTheOpenPhoto(edit: SearchScreenEdit) async {
        let fixture = SearchScreenFixture()
        await fixture.search("recipe")
        fixture.store.select(searchScreenPhoto("recipe"))
        #expect(fixture.store.selectedPhoto?.id == "recipe")

        fixture.edit(edit)
        #expect(fixture.store.matches.isEmpty)
        #expect(fixture.store.selectedPhoto == nil)
        #expect(fixture.store.message == nil)
        await fixture.store.waitForIdle()
        #expect(fixture.engine.requests.count == 1)
    }

    @Test(arguments: SearchScreenEdit.allCases)
    func anEditRejectsALatePredictionEvenWhenNativeWorkIgnoresCancellation(edit: SearchScreenEdit) async throws {
        let fixture = SearchScreenFixture()
        defer { fixture.engine.releaseAll() }
        fixture.engine.heldQueries = ["recipe"]
        fixture.store.activate()
        fixture.store.text = "recipe"
        fixture.store.search()
        try await searchScreenEventually { fixture.engine.isWaiting(for: "recipe") }
        #expect(fixture.store.phase == .searching)
        #expect(fixture.store.isWorking)

        fixture.edit(edit)
        #expect(fixture.store.matches.isEmpty)
        fixture.engine.release("recipe")
        await fixture.store.waitForIdle()

        #expect(fixture.store.matches.isEmpty)
        #expect(fixture.store.message == nil)
        #expect(fixture.engine.requests.count == 1)
        #expect(fixture.engine.maximumConcurrentOperations == 1)
        #expect(!fixture.store.isWorking)
    }

    @Test
    func resubmissionQueuesOnlyTheLatestRequestAndWaitsForTheOldPrediction() async throws {
        let fixture = SearchScreenFixture()
        defer { fixture.engine.releaseAll() }
        fixture.engine.heldQueries = ["first"]
        fixture.store.activate()
        fixture.store.text = "first"
        fixture.store.search()
        try await searchScreenEventually { fixture.engine.isWaiting(for: "first") }

        fixture.store.text = "second"
        fixture.store.search()
        fixture.store.text = "latest"
        fixture.store.language = .english
        fixture.store.search()
        #expect(fixture.engine.requests.map(\.text) == ["first"])
        fixture.engine.release("first")
        await fixture.store.waitForIdle()

        #expect(fixture.engine.requests.map(\.text) == ["first", "latest"])
        #expect(fixture.engine.requests.last?.language == .english)
        #expect(fixture.store.matches.map(\.photo.id) == ["latest"])
        #expect(fixture.store.phase == .results)
        #expect(fixture.engine.maximumConcurrentOperations == 1)
    }

    @Test
    func editingAfterAQueuedSubmissionDropsThatSubmission() async throws {
        let fixture = SearchScreenFixture()
        defer { fixture.engine.releaseAll() }
        fixture.engine.heldQueries = ["first"]
        fixture.store.activate()
        fixture.store.text = "first"
        fixture.store.search()
        try await searchScreenEventually { fixture.engine.isWaiting(for: "first") }

        fixture.store.text = "queued"
        fixture.store.search()
        fixture.store.text = "still typing"
        fixture.engine.release("first")
        await fixture.store.waitForIdle()

        #expect(fixture.engine.requests.map(\.text) == ["first"])
        #expect(fixture.store.matches.isEmpty)
        #expect(fixture.store.message == nil)
    }

    @Test
    func explicitCancellationDiscardsLateResultsAndPendingSubmission() async throws {
        let fixture = SearchScreenFixture()
        defer { fixture.engine.releaseAll() }
        fixture.engine.heldQueries = ["first"]
        fixture.store.activate()
        fixture.store.text = "first"
        fixture.store.search()
        try await searchScreenEventually { fixture.engine.isWaiting(for: "first") }
        fixture.store.text = "queued"
        fixture.store.search()

        fixture.store.cancel()
        fixture.engine.release("first")
        await fixture.store.waitForIdle()

        #expect(fixture.engine.requests.map(\.text) == ["first"])
        #expect(fixture.store.matches.isEmpty)
        #expect(fixture.store.message == nil)
        #expect(!fixture.store.isWorking)
    }

    @Test
    func successfulQueriesKeepModelsWarmUntilDeactivation() async {
        let fixture = SearchScreenFixture()
        await fixture.search("first")
        await fixture.search("second")
        #expect(fixture.engine.unloadCount == 0)
        fixture.store.deactivate()
        #expect(fixture.store.matches.isEmpty)
        await fixture.store.waitForIdle()
        #expect(fixture.engine.unloadCount == 1)
    }

    @Test
    func deactivationWaitsForPredictionBeforeUnloadingAndRejectsSearchWhileInactive() async throws {
        let fixture = SearchScreenFixture()
        defer { fixture.engine.releaseAll() }
        fixture.engine.heldQueries = ["recipe"]
        fixture.store.activate()
        fixture.store.text = "recipe"
        fixture.store.search()
        try await searchScreenEventually { fixture.engine.isWaiting(for: "recipe") }

        fixture.store.deactivate()
        fixture.store.search()
        #expect(fixture.engine.unloadCount == 0)
        #expect(fixture.store.matches.isEmpty)
        fixture.engine.release("recipe")
        await fixture.store.waitForIdle()

        #expect(fixture.engine.requests.count == 1)
        #expect(fixture.engine.unloadCount == 1)
        #expect(fixture.engine.maximumConcurrentOperations == 1)
        #expect(fixture.store.matches.isEmpty)
        #expect(fixture.store.message == nil)
    }

    @Test
    func quickReactivationWaitsForBothCancelledWorkAndResourceUnloading() async throws {
        let fixture = SearchScreenFixture()
        defer { fixture.engine.releaseAll() }
        fixture.engine.heldQueries = ["first"]
        fixture.engine.holdUnload = true
        fixture.store.activate()
        fixture.store.text = "first"
        fixture.store.search()
        try await searchScreenEventually { fixture.engine.isWaiting(for: "first") }

        fixture.store.deactivate()
        fixture.store.activate()
        fixture.store.text = "next"
        fixture.store.search()
        fixture.engine.release("first")
        try await searchScreenEventually { fixture.engine.isUnloading }
        #expect(fixture.engine.requests.map(\.text) == ["first"])
        fixture.engine.releaseUnload()
        await fixture.store.waitForIdle()

        #expect(fixture.engine.requests.map(\.text) == ["first", "next"])
        #expect(fixture.engine.events == ["search:first", "unload", "search:next"])
        #expect(fixture.engine.maximumConcurrentOperations == 1)
        #expect(fixture.store.matches.map(\.photo.id) == ["next"])
    }

    @Test
    func libraryInvalidationClearsPublishedResultsAndSelectionSynchronously() async {
        let fixture = SearchScreenFixture()
        await fixture.search("recipe")
        fixture.store.select(searchScreenPhoto("recipe"))
        fixture.store.invalidateLibrary()

        #expect(fixture.store.matches.isEmpty)
        #expect(fixture.store.selectedPhoto == nil)
        await fixture.store.waitForIdle()
        #expect(fixture.engine.unloadCount == 1)
    }

    @Test
    func libraryInvalidationRejectsInFlightResultsAndUnloadsAfterTheyDrain() async throws {
        let fixture = SearchScreenFixture()
        defer { fixture.engine.releaseAll() }
        fixture.engine.heldQueries = ["recipe"]
        fixture.store.activate()
        fixture.store.text = "recipe"
        fixture.store.search()
        try await searchScreenEventually { fixture.engine.isWaiting(for: "recipe") }

        fixture.store.invalidateLibrary()
        #expect(fixture.engine.unloadCount == 0)
        fixture.engine.release("recipe")
        await fixture.store.waitForIdle()

        #expect(fixture.store.matches.isEmpty)
        #expect(fixture.store.message == nil)
        #expect(fixture.engine.unloadCount == 1)
        #expect(fixture.engine.maximumConcurrentOperations == 1)
    }

    @Test
    func queuedSearchRechecksIndexReadinessBeforeLoadingModels() async throws {
        let fixture = SearchScreenFixture()
        defer { fixture.engine.releaseAll() }
        fixture.engine.heldQueries = ["first"]
        fixture.store.activate()
        fixture.store.text = "first"
        fixture.store.search()
        try await searchScreenEventually { fixture.engine.isWaiting(for: "first") }

        fixture.store.text = "next"
        fixture.store.search()
        fixture.state = PhotoSearchIndexState(isReady: false, summary: .empty, message: nil)
        fixture.engine.release("first")
        await fixture.store.waitForIdle()

        #expect(fixture.engine.requests.map(\.text) == ["first"])
        #expect(fixture.store.phase == .waitingForIndex)
        #expect(fixture.store.matches.isEmpty)
    }

    @Test
    func dismissingTheViewerPreservesTheSubmittedQueryAndResults() async {
        let fixture = SearchScreenFixture()
        await fixture.search("recipe")
        let context = fixture.store.resultContext
        let snippets = fixture.store.snippets
        fixture.store.recordScrollOffset(712.5)
        fixture.store.select(searchScreenPhoto("recipe"))
        #expect(fixture.store.viewerReturnOffset == 712.5)
        fixture.store.recordScrollOffset(0)
        #expect(fixture.store.resultsScrollOffset == 712.5)
        fixture.store.dismissPhoto()

        #expect(fixture.store.selectedPhoto == nil)
        #expect(fixture.store.text == "recipe")
        #expect(fixture.store.phase == .results)
        #expect(fixture.store.matches.map(\.photo.id) == ["recipe"])
        #expect(fixture.store.resultContext == context)
        #expect(fixture.store.snippets == snippets)
        #expect(fixture.store.resultsScrollOffset == 712.5)
        #expect(fixture.store.viewerReturnOffset == 712.5)
        // Dismissal can produce a temporary top-of-screen geometry update.
        fixture.store.recordScrollOffset(0)
        #expect(fixture.store.resultsScrollOffset == 712.5)
        #expect(fixture.store.takeViewerReturnOffset() == 712.5)
        #expect(fixture.store.takeViewerReturnOffset() == nil)
        fixture.store.recordScrollOffset(800)
        #expect(fixture.store.resultsScrollOffset == 800)
        #expect(fixture.engine.requests.count == 1)
    }

    @Test
    func resultCoverageDescribesTheIndexAtDispatchAndDoesNotDriftWhileSearching() async throws {
        let fixture = SearchScreenFixture()
        defer { fixture.engine.releaseAll() }
        let dispatchedSummary = searchScreenSummary(embeddings: 2, ocr: 1, pending: 8)
        fixture.state = PhotoSearchIndexState(isReady: true, summary: dispatchedSummary, message: nil)
        fixture.engine.heldQueries = ["recipe"]
        fixture.store.activate()
        fixture.store.text = "recipe"
        fixture.store.search()
        try await searchScreenEventually { fixture.engine.isWaiting(for: "recipe") }
        #expect(fixture.store.resultContext == nil)

        fixture.state = PhotoSearchIndexState(isReady: true,
            summary: searchScreenSummary(embeddings: 10, ocr: 10), message: nil)
        fixture.engine.release("recipe")
        await fixture.store.waitForIdle()

        #expect(fixture.store.resultContext == PhotoSearchResultContext(query: "recipe",
            coverage: PhotoSearchCoverage(summary: dispatchedSummary, mode: .combined)))
        #expect(fixture.store.resultContext?.coverage.isComplete == false)
        #expect(fixture.store.currentIndex.summary.completeCount == 10)
    }

    @Test
    func queuedSearchCapturesCoverageAfterEarlierWorkAndUnloadingFinish() async throws {
        let fixture = SearchScreenFixture()
        defer { fixture.engine.releaseAll() }
        fixture.engine.heldQueries = ["first"]
        fixture.engine.holdUnload = true
        fixture.store.activate()
        fixture.store.text = "first"
        fixture.store.search()
        try await searchScreenEventually { fixture.engine.isWaiting(for: "first") }

        fixture.store.deactivate()
        fixture.store.activate()
        fixture.store.mode = .textOnly
        fixture.store.text = "next"
        fixture.store.search()
        fixture.engine.release("first")
        try await searchScreenEventually { fixture.engine.isUnloading }
        #expect(fixture.store.resultContext == nil)
        #expect(fixture.engine.requests.map(\.text) == ["first"])

        let latestSummary = searchScreenSummary(embeddings: 0, ocr: 6, pending: 4)
        fixture.state = PhotoSearchIndexState(isReady: true, summary: latestSummary, message: nil)
        fixture.engine.releaseUnload()
        await fixture.store.waitForIdle()

        #expect(fixture.store.resultContext == PhotoSearchResultContext(query: "next",
            coverage: PhotoSearchCoverage(summary: latestSummary, mode: .textOnly)))
        #expect(fixture.engine.events == ["search:first", "unload", "search:next"])
    }

    @Test
    func noMatchesStillPublishesCoverageForTheSubmittedQuery() async {
        let fixture = SearchScreenFixture()
        fixture.engine.emptyResults = true
        await fixture.search("рецепт")

        #expect(fixture.store.phase == .noMatches)
        #expect(fixture.store.resultContext?.query == "рецепт")
        #expect(fixture.store.resultContext?.coverage.summary == fixture.state.summary)
        #expect(fixture.store.snippets.isEmpty)
        fixture.store.recordScrollOffset(100)
        #expect(fixture.store.resultsScrollOffset == 0)
    }

    @Test
    func snippetsAreKeyedByPhotoAndUseTheOriginalRussianQuery() async {
        let fixture = SearchScreenFixture()
        let recognizedText = "Сохранённый рецепт яблочного пирога с корицей"
        fixture.engine.resultOverride = [
            PhotoSearchMatch(photo: searchScreenPhoto("ocr-photo"), score: 0.02,
                visualSimilarity: nil, recognizedText: recognizedText),
            PhotoSearchMatch(photo: searchScreenPhoto("visual-photo"), score: 0.01,
                visualSimilarity: 0.6, recognizedText: nil)
        ]
        await fixture.search("пирога")

        #expect(Set(fixture.store.snippets.keys) == ["ocr-photo"])
        #expect(fixture.store.snippets["ocr-photo"] ==
            PhotoSearchSnippet.make(recognizedText: recognizedText, query: "пирога"))
        #expect(fixture.store.snippets["visual-photo"] == nil)
        #expect(fixture.store.resultContext?.query == "пирога")
    }

    @Test
    func scrollOffsetsRequireVisibleResultsAndFiniteNonnegativeValues() async {
        let fixture = SearchScreenFixture()
        fixture.store.recordScrollOffset(100)
        #expect(fixture.store.resultsScrollOffset == 0)
        await fixture.search("recipe")

        fixture.store.recordScrollOffset(123.25)
        fixture.store.recordScrollOffset(.nan)
        fixture.store.recordScrollOffset(.infinity)
        fixture.store.recordScrollOffset(-.infinity)
        #expect(fixture.store.resultsScrollOffset == 123.25)
        fixture.store.recordScrollOffset(-40)
        #expect(fixture.store.resultsScrollOffset == 0)
        fixture.store.recordScrollOffset(456)
        fixture.store.select(searchScreenPhoto("unlisted-photo"))
        #expect(fixture.store.viewerReturnOffset == nil)
        #expect(fixture.store.selectedPhoto == nil)
        fixture.store.cancel()
        fixture.store.recordScrollOffset(200)
        #expect(fixture.store.resultsScrollOffset == 0)
    }

    @Test(arguments: SearchResultResetAction.allCases)
    func resettingResultsClearsTheirContextSnippetsAndPendingViewerPosition(action: SearchResultResetAction) async {
        let fixture = SearchScreenFixture()
        await fixture.search("recipe")
        fixture.store.recordScrollOffset(600)
        fixture.store.select(searchScreenPhoto("recipe"))
        #expect(fixture.store.resultContext != nil)
        #expect(!fixture.store.snippets.isEmpty)
        #expect(fixture.store.viewerReturnOffset == 600)

        switch action {
        case .text: fixture.store.text = "new recipe"
        case .language: fixture.store.language = .english
        case .mode: fixture.store.mode = .textOnly
        case .library: fixture.store.invalidateLibrary()
        case .deactivate: fixture.store.deactivate()
        case .cancel: fixture.store.cancel()
        case .failedSearch:
            fixture.engine.nextError = QueryTranslationError.modelUnavailable
            fixture.store.search()
        case .invalidQuery:
            fixture.store.text = ""
            fixture.store.search()
        }

        #expect(fixture.store.matches.isEmpty)
        #expect(fixture.store.selectedPhoto == nil)
        #expect(fixture.store.resultContext == nil)
        #expect(fixture.store.snippets.isEmpty)
        #expect(fixture.store.resultsScrollOffset == 0)
        #expect(fixture.store.takeViewerReturnOffset() == nil)
        // A stale cover-dismiss callback cannot recover the old position.
        fixture.store.dismissPhoto()
        await fixture.store.waitForIdle()
        #expect(fixture.store.resultContext == nil)
        #expect(fixture.store.snippets.isEmpty)
        #expect(fixture.store.viewerReturnOffset == nil)
        if action == .failedSearch || action == .invalidQuery {
            #expect(fixture.store.phase == .failed)
        }
    }

    @Test
    func translationFailureCanBeRetriedExplicitlyInTextOnlyMode() async {
        let fixture = SearchScreenFixture()
        fixture.engine.nextError = QueryTranslationError.modelUnavailable
        await fixture.search("рецепт")
        #expect(fixture.store.phase == .failed)
        #expect(fixture.store.message?.isEmpty == false)
        #expect(fixture.store.matches.isEmpty)

        fixture.store.mode = .textOnly
        fixture.store.search()
        await fixture.store.waitForIdle()
        #expect(fixture.store.phase == .results)
        #expect(fixture.engine.requests.map(\.mode) == [.combined, .textOnly])
        #expect(fixture.store.message == nil)
    }

    @Test
    func arbitraryEngineErrorsDoNotExposeTheirLocalizedDescription() async {
        let fixture = SearchScreenFixture()
        fixture.engine.nextError = NSError(domain: "private.example", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "private-secret-photo-and-query"])
        await fixture.search("recipe")

        #expect(fixture.store.phase == .failed)
        #expect(fixture.store.message?.isEmpty == false)
        #expect(fixture.store.message?.contains("private-secret") == false)
        #expect(fixture.store.matches.isEmpty)
    }

    @Test
    func cancellationErrorsDoNotBecomeUserVisibleFailures() async {
        let fixture = SearchScreenFixture()
        fixture.engine.nextError = CancellationError()
        await fixture.search("recipe")

        #expect(fixture.store.phase != .failed)
        #expect(fixture.store.message == nil)
        #expect(fixture.store.matches.isEmpty)
        #expect(!fixture.store.isWorking)
    }
}

nonisolated enum SearchScreenEdit: CaseIterable, Sendable {
    case text, language, mode
}

nonisolated enum SearchResultResetAction: CaseIterable, Sendable {
    case text, language, mode, library, deactivate, cancel, failedSearch, invalidQuery
}

@MainActor
private final class SearchScreenFixture {
    let engine = SearchScreenEngine()
    var state = PhotoSearchIndexState(isReady: true, summary: searchScreenSummary(), message: nil)
    lazy var store = PhotoSearchStore(engine: engine, indexState: { [weak self] in
        self?.state ?? PhotoSearchIndexState(isReady: false, summary: .empty, message: nil)
    })

    func search(_ text: String) async {
        store.activate()
        store.text = text
        store.search()
        await store.waitForIdle()
    }

    func edit(_ change: SearchScreenEdit) {
        switch change {
        case .text: store.text = "edited recipe"
        case .language: store.language = .english
        case .mode: store.mode = .textOnly
        }
    }
}

@MainActor
private final class SearchScreenEngine: PhotoSearchServing {
    struct Request {
        let text: String
        let language: QueryLanguageChoice
        let mode: PhotoSearchMode
        let limit: Int
    }

    var heldQueries: Set<String> = []
    var holdUnload = false
    var emptyResults = false
    var resultOverride: [PhotoSearchMatch]?
    var nextError: (any Error)?
    private(set) var requests: [Request] = []
    private(set) var unloadCount = 0
    private(set) var maximumConcurrentOperations = 0
    private(set) var events: [String] = []
    private var activeOperations = 0
    private var queries: [String: CheckedContinuation<Void, Never>] = [:]
    private var unloadContinuation: CheckedContinuation<Void, Never>?
    var isUnloading: Bool { unloadContinuation != nil }

    @MainActor
    func search(_ text: String, language: QueryLanguageChoice, mode: PhotoSearchMode,
                limit: Int) async throws -> [PhotoSearchMatch] {
        beginOperation()
        defer { activeOperations -= 1 }
        requests.append(Request(text: text, language: language, mode: mode, limit: limit))
        events.append("search:\(text)")
        let error = nextError
        nextError = nil
        let shouldReturnEmpty = emptyResults
        let suppliedResults = resultOverride
        if heldQueries.remove(text) != nil {
            await withCheckedContinuation { queries[text] = $0 }
        }
        if let error { throw error }
        if shouldReturnEmpty { return [] }
        if let suppliedResults { return suppliedResults }
        return [PhotoSearchMatch(photo: searchScreenPhoto(text), score: 0.02,
            visualSimilarity: mode == .combined ? 0.4 : nil, recognizedText: "recipe")]
    }

    @MainActor
    func unload() async {
        beginOperation()
        defer { activeOperations -= 1 }
        unloadCount += 1
        events.append("unload")
        if holdUnload {
            holdUnload = false
            await withCheckedContinuation { unloadContinuation = $0 }
        }
    }

    func isWaiting(for text: String) -> Bool { queries[text] != nil }
    func release(_ text: String) { queries.removeValue(forKey: text)?.resume() }
    func releaseUnload() {
        let pending = unloadContinuation
        unloadContinuation = nil
        pending?.resume()
    }
    func releaseAll() {
        heldQueries = []
        holdUnload = false
        let pending = queries
        queries = [:]
        for continuation in pending.values { continuation.resume() }
        releaseUnload()
    }
    private func beginOperation() {
        activeOperations += 1
        maximumConcurrentOperations = max(maximumConcurrentOperations, activeOperations)
    }
}

private func searchScreenPhoto(_ id: String) -> LibraryPhoto {
    LibraryPhoto(id: id, creationDate: nil, modificationDate: nil, pixelWidth: 100, pixelHeight: 100)
}

private func searchScreenSummary(embeddings: Int = 1, ocr: Int = 1, pending: Int = 0) -> PhotoIndexSummary {
    PhotoIndexSummary(totalCount: max(embeddings, ocr) + pending, completeCount: min(embeddings, ocr),
        embeddingCount: embeddings, ocrCount: ocr, pendingCount: pending,
        downloadRequiredCount: 0, failedCount: 0)
}

@MainActor
private func searchScreenEventually(_ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw SearchScreenTestError.timedOut
}

private enum SearchScreenTestError: Error { case timedOut }
