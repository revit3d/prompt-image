import CoreGraphics
import Foundation
import Testing
@testable import PromptImage

/// Exercises query preparation and retrieval together against the index owner's
/// real database, without accessing Photos or loading inference models.
@MainActor
struct PhotoSearchPipelineTests {
    @Test
    func russianSearchUsesOriginalOCRTextAndTranslatedVisualEmbedding() async throws {
        try await withSearchFixture { fixture in
            try await fixture.prepare(["both", "visual", "text"])
            try await fixture.seed("both", visual: true, text: "Кошка на диване")
            try await fixture.seed("visual", visual: true, text: "unrelated English text")
            try await fixture.seed("text", visual: false, text: "Кошка на диване")

            let matches = try await fixture.pipeline.search(" \nКошка на диване\t ", language: .russian)

            #expect(fixture.translator.requests == ["Кошка на диване"])
            #expect(fixture.translator.languagePairs == ["ru/en"])
            #expect(fixture.encoder.texts == ["a cat on a sofa"])
            #expect(Set(matches.map(\.photo.id)) == ["both", "visual", "text"])
            #expect(matches.count == 3)
            let both = try #require(matches.first { $0.photo.id == "both" })
            let text = try #require(matches.first { $0.photo.id == "text" })
            let visual = try #require(matches.first { $0.photo.id == "visual" })
            #expect(both.visualSimilarity != nil)
            #expect(both.recognizedText == "Кошка на диване")
            #expect(text.visualSimilarity == nil)
            #expect(text.recognizedText == "Кошка на диване")
            #expect(visual.visualSimilarity != nil)
            #expect(visual.recognizedText == nil)
            #expect(matches.allSatisfy { $0.score.isFinite && $0.score > 0 })
        }
    }

    @Test
    func englishSearchBypassesAnUnavailableTranslator() async throws {
        try await withSearchFixture { fixture in
            fixture.translator.status = .modelUnavailable
            try await fixture.prepare(["recipe"])
            try await fixture.seed("recipe", visual: true, text: "pancake recipe")

            let matches = try await fixture.pipeline.search("  pancake recipe  ", language: .english)

            #expect(matches.map(\.photo.id) == ["recipe"])
            #expect(matches.first?.recognizedText == "pancake recipe")
            #expect(fixture.translator.requests.isEmpty)
            #expect(fixture.translator.availabilityCalls == 0)
            #expect(fixture.encoder.texts == ["pancake recipe"])
        }
    }

    @Test
    func incompatibleQueryModelFailsInsteadOfReturningOCRAsASilentFallback() async throws {
        try await withSearchFixture { fixture in
            try await fixture.prepare(["recipe"])
            try await fixture.seed("recipe", visual: true, text: "recipe")
            fixture.encoder.setModelID("different-clip-model")

            await #expect(throws: CLIPEmbeddingError.incompatibleModels) {
                try await fixture.pipeline.search("recipe", language: .english)
            }
        }
    }

    @Test(arguments: ["", " \n\t "])
    func emptyQueriesAreRejectedBeforeInference(query: String) async throws {
        try await withSearchFixture { fixture in
            try await fixture.prepare(["a"])
            await #expect(throws: QueryInputError.empty) {
                try await fixture.pipeline.search(query, language: .russian)
            }
            #expect(fixture.translator.availabilityCalls == 0)
            #expect(fixture.encoder.texts.isEmpty)
        }
    }

    @Test(arguments: [String(repeating: "a", count: 4_097), String(repeating: "я", count: 2_049),
                      Array(repeating: "слово", count: 33).joined(separator: " "),
                      Array(repeating: "word", count: 33).joined(separator: "-")])
    func oversizedQueriesAreRejectedBeforeInference(query: String) async throws {
        try await withSearchFixture { fixture in
            try await fixture.prepare(["a"])
            await #expect(throws: QueryInputError.tooLong) {
                try await fixture.pipeline.search(query, language: .russian)
            }
            #expect(fixture.translator.availabilityCalls == 0)
            #expect(fixture.translator.requests.isEmpty)
            #expect(fixture.encoder.texts.isEmpty)
        }
    }

    @Test(arguments: [0, -1, 101, Int.max])
    func invalidLimitsAreRejectedBeforeInference(limit: Int) async throws {
        try await withSearchFixture { fixture in
            try await fixture.prepare(["a"])
            await #expect(throws: PhotoSearchError.invalidLimit) {
                try await fixture.pipeline.search("рецепт", language: .russian, limit: limit)
            }
            #expect(fixture.translator.availabilityCalls == 0)
            #expect(fixture.encoder.texts.isEmpty)
        }
    }

    @Test(arguments: [String(repeating: "a", count: 4_096),
                      Array(repeating: "word", count: 32).joined(separator: " ")])
    func queriesAtTheBoundsCanReachInference(query: String) async throws {
        try await withSearchFixture { fixture in
            try await fixture.prepare(["a"])
            try await fixture.seed("a", visual: true)
            let matches = try await fixture.pipeline.search(query, language: .english, limit: 100)
            #expect(matches.map(\.photo.id) == ["a"])
            #expect(fixture.encoder.texts == [query])
        }
    }

    @Test
    func anUnsynchronizedIndexRejectsSearchBeforeLoadingModelsOrOpeningStorage() async throws {
        try await withSearchFixture { fixture in
            await #expect(throws: PhotoSearchError.indexNotReady) {
                try await fixture.pipeline.search("рецепт", language: .russian)
            }
            #expect(fixture.translator.availabilityCalls == 0)
            #expect(fixture.encoder.texts.isEmpty)
            #expect(await fixture.opener.openCount == 0)
        }
    }

    @Test(arguments: SearchInvalidation.allCases)
    func aQuerySuspendedInInferenceCannotPublishAfterLibraryInvalidation(
        invalidation: SearchInvalidation
    ) async throws {
        try await withSearchFixture { fixture in
            try await fixture.prepare(["a"])
            try await fixture.seed("a", visual: true, text: "recipe")
            fixture.encoder.holdNext()
            let task = Task { try await fixture.pipeline.search("recipe", language: .english) }
            try await searchEventually { fixture.encoder.isWaiting }

            switch invalidation {
            case .permission:
                fixture.accessibleIDs = []
                fixture.index.revokeAccess()
            case .activity:
                fixture.index.setActive(false)
            case .snapshot:
                fixture.index.updatePhotos([searchPhoto("a")])
            case .content:
                fixture.index.libraryDidChange(PhotoLibraryChange(contentChangedIDs: ["a"]))
                fixture.index.updatePhotos([searchPhoto("a")])
            case .library:
                fixture.index.invalidateLibrary()
            case .rebuild:
                fixture.index.rebuild()
            }
            await fixture.index.waitForIdle()
            fixture.encoder.release()

            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }

    @Test
    func cancellationDuringInferenceRejectsALateModelResult() async throws {
        try await withSearchFixture { fixture in
            try await fixture.prepare(["a"])
            try await fixture.seed("a", visual: true)
            fixture.encoder.holdNext()
            let task = Task { try await fixture.pipeline.search("recipe", language: .english) }
            try await searchEventually { fixture.encoder.isWaiting }
            task.cancel()
            fixture.encoder.release()

            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }

    @Test
    func finalAccessCheckFiltersLostAccessBeforeTheObserverNotifiesTheIndex() async throws {
        try await withSearchFixture { fixture in
            try await fixture.prepare(["keep", "lost"])
            try await fixture.seed("keep", visual: true, text: "recipe")
            try await fixture.seed("lost", visual: true, text: "recipe")
            fixture.encoder.holdNext()
            let task = Task { try await fixture.pipeline.search("recipe", language: .english) }
            try await searchEventually { fixture.encoder.isWaiting }

            // The permitted snapshot and stored rows are deliberately unchanged.
            fixture.accessibleIDs = ["keep"]
            fixture.encoder.release()

            #expect(try await task.value.map(\.photo.id) == ["keep"])
            #expect(try await fixture.database.record(for: "lost") != nil)
        }
    }

    @Test
    func completedStagesRemainSearchableWithoutRecoveringTheRunningWorkersTicket() async throws {
        try await withSearchFixture { fixture in
            fixture.processor.holdNextEmbedding("b")
            try await fixture.prepare(["a", "b"])
            fixture.index.start()
            try await searchEventually { fixture.processor.isWaiting }
            let pending = try #require(try await fixture.database.record(for: "b"))
            #expect(pending.embedding.status == .processing)
            #expect(fixture.index.isBusy)

            let matches = try await fixture.pipeline.search("recipe", language: .english)

            #expect(matches.map(\.photo.id) == ["a"])
            #expect(try await fixture.database.record(for: "b") == pending)
            #expect(await fixture.opener.openCount == 1)
            #expect(fixture.processor.embeddingIDs == ["a", "b"])
            fixture.processor.release()
            try await searchEventually { !fixture.index.isBusy && fixture.index.phase == .finished }
            #expect(try await fixture.database.record(for: "b")?.embedding.status == .complete)
            #expect(fixture.processor.embeddingIDs == ["a", "b"])
        }
    }

    @Test
    func unloadReleasesBothQueryModels() async throws {
        try await withSearchFixture { fixture in
            await fixture.pipeline.unload()
            #expect(fixture.translator.unloadCount == 1)
            #expect(fixture.encoder.unloadCount == 1)
        }
    }
}

nonisolated enum SearchInvalidation: CaseIterable, Sendable {
    case permission, activity, snapshot, content, library, rebuild
}

private let searchVersions = PhotoIndexVersions(embedding: "clip-search-test", ocr: "ocr-search-test")

private func searchPhoto(_ id: String) -> LibraryPhoto {
    LibraryPhoto(id: id, creationDate: nil, modificationDate: nil, pixelWidth: 100, pixelHeight: 100)
}

private func searchEmbedding(modelID: String = "clip-search-test") throws -> CLIPEmbedding {
    try CLIPEmbedding(rawValues: [1] + Array(repeating: 0, count: 511), modelID: modelID)
}

private func searchOCR(_ text: String) -> PhotoOCRResult {
    PhotoOCRResult(lines: [PhotoOCRLine(text: text, confidence: 0.9,
        boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.2))], revision: 3, languages: ["ru-RU", "en-US"])
}

@MainActor
private func searchEventually(_ condition: @MainActor () async throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw SearchFixtureError.timedOut
}

private enum SearchFixtureError: Error { case timedOut }

@MainActor
private func withSearchFixture(_ body: (SearchFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Search-\(UUID().uuidString)")
    let fixture = try SearchFixture(directory: directory)
    do {
        try await body(fixture)
        await fixture.finish()
        try FileManager.default.removeItem(at: directory)
    } catch {
        await fixture.finish()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

@MainActor
private final class SearchFixture {
    let database: PhotoIndexStore
    let opener: SearchStoreOpener
    let processor = SearchIndexProcessor()
    let translator = SearchTranslator()
    let encoder = SearchTextEncoder()
    var accessibleIDs: Set<String> = []
    lazy var index = PhotoIndexingStore(provider: SearchPhotoSource(), processor: processor,
        openStore: { [opener] in await opener.open() },
        isCurrentAndAccessible: { [weak self] in self?.accessibleIDs.contains($0.id) == true })
    lazy var pipeline = PhotoSearchPipeline(
        queryPipeline: QueryEmbeddingPipeline(translator: translator, encoder: encoder), index: index)

    init(directory: URL) throws {
        database = try PhotoIndexStore(directoryURL: directory)
        opener = SearchStoreOpener(database: database)
    }

    func prepare(_ ids: [String]) async throws {
        accessibleIDs = Set(ids)
        index.setActive(true)
        index.updatePhotos(ids.map(searchPhoto))
        try await searchEventually { !self.index.isBusy && self.index.phase == .ready }
    }

    func seed(_ id: String, visual: Bool, text: String? = nil) async throws {
        if visual {
            let ticket = try await database.beginWork(for: id, stage: .embedding)
            try await database.saveEmbedding(searchEmbedding(), for: ticket)
        }
        if let text {
            let ticket = try await database.beginWork(for: id, stage: .ocr)
            try await database.saveOCR(searchOCR(text), for: ticket)
        }
    }

    func finish() async {
        index.pause()
        processor.release()
        encoder.release()
        await index.waitForIdle()
        try? await database.close()
    }
}

private actor SearchStoreOpener {
    let database: PhotoIndexStore
    private(set) var openCount = 0

    init(database: PhotoIndexStore) { self.database = database }

    func open() -> PhotoIndexStore {
        openCount += 1
        return database
    }
}

@MainActor
private final class SearchPhotoSource: PhotoOCRSourceProviding {
    func requestSource(for photo: LibraryPhoto,
                       completion: @escaping @MainActor (PhotoOCRSourceResult) -> Void) -> UUID {
        completion(.source(PhotoOCRSource(data: Data(photo.id.utf8), orientation: .up)))
        return UUID()
    }

    func cancel(_ requestID: UUID) { }
}

@MainActor
private final class SearchIndexProcessor: PhotoIndexProcessing {
    private var heldID: String?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var embeddingIDs: [String] = []
    var isWaiting: Bool { continuation != nil }

    @MainActor func versions() async throws -> PhotoIndexVersions { searchVersions }

    @MainActor func embedding(_ source: PhotoOCRSource) async throws -> CLIPEmbedding {
        let id = String(decoding: source.data, as: UTF8.self)
        embeddingIDs.append(id)
        if heldID == id {
            heldID = nil
            await withCheckedContinuation { continuation = $0 }
        }
        return try searchEmbedding()
    }

    @MainActor func recognize(_ source: PhotoOCRSource) async throws -> PhotoOCRResult {
        searchOCR("recipe \(String(decoding: source.data, as: UTF8.self))")
    }

    @MainActor func unload() async { }
    func holdNextEmbedding(_ id: String) { heldID = id }
    func release() {
        let pending = continuation
        continuation = nil
        heldID = nil
        pending?.resume()
    }
}

@MainActor
private final class SearchTranslator: QueryTranslating {
    var status = QueryTranslationAvailability.ready
    private(set) var availabilityCalls = 0
    private(set) var requests: [String] = []
    private(set) var languagePairs: [String] = []
    private(set) var unloadCount = 0

    func availability() async -> QueryTranslationAvailability {
        availabilityCalls += 1
        return status
    }

    func translate(_ text: String, from source: QueryLanguage, to target: QueryLanguage) async throws -> String {
        requests.append(text)
        languagePairs.append("\(source.rawValue)/\(target.rawValue)")
        return "a cat on a sofa"
    }

    func unload() async { unloadCount += 1 }
}

@MainActor
private final class SearchTextEncoder: QueryTextEncoding {
    private var modelID = "clip-search-test"
    private var shouldHold = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var texts: [String] = []
    private(set) var unloadCount = 0
    var isWaiting: Bool { continuation != nil }

    init() { }

    @MainActor func textEmbedding(_ text: String) async throws -> CLIPEmbedding {
        texts.append(text)
        if shouldHold {
            shouldHold = false
            // Model inference may finish after cancellation or a Photos event.
            await withCheckedContinuation { continuation = $0 }
        }
        return try searchEmbedding(modelID: modelID)
    }

    func setModelID(_ modelID: String) { self.modelID = modelID }
    func holdNext() { shouldHold = true }
    func release() {
        let pending = continuation
        continuation = nil
        shouldHold = false
        pending?.resume()
    }
    @MainActor func unload() async { unloadCount += 1 }
}
