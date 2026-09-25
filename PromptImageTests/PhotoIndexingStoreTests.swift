import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PromptImage

/// Synthetic sources and a real temporary database exercise the foreground worker
/// without reading Photos or loading the bundled models.
@MainActor
struct PhotoIndexingStoreTests {
    @Test
    func openingAndSynchronizingRequiresAnExplicitStart() async throws {
        try await withIndexingFixture { fixture in
            try await fixture.prepare([indexingPhoto("a")])

            #expect(fixture.store.phase == .ready)
            #expect(!fixture.store.wantsToRun)
            #expect(fixture.source.requests.isEmpty)
            #expect(fixture.processor.embeddingIDs.isEmpty)
            #expect(fixture.store.summary.pendingCount == 1)
            let record = try #require(try await fixture.database.record(for: "a"))
            #expect(record.embedding.status == .pending)
            #expect(record.ocr.status == .pending)

            fixture.store.start()
            try await fixture.waitUntilFinished()
            #expect(fixture.store.summary.completeCount == 1)
            #expect(fixture.source.requests.map(\.photo.id) == ["a"])
        }
    }

    @Test
    func completedStagesAreSearchableWhileALaterPhotoIsStillRunning() async throws {
        try await withIndexingFixture { fixture in
            fixture.processor.holdNext("b", stage: .embedding)
            try await fixture.prepare([indexingPhoto("b"), indexingPhoto("a")])
            fixture.store.start()
            try await indexingEventually { fixture.processor.isWaiting("b", stage: .embedding) }

            #expect(fixture.store.isBusy)
            #expect(fixture.store.summary.completeCount == 1)
            #expect(fixture.store.summary.embeddingCount == 1)
            #expect(fixture.store.summary.ocrCount == 1)
            let embeddings = try await fixture.database.embeddings(modelID: indexingVersions.embedding)
            let text = try await fixture.database.searchOCR("recipe", version: indexingVersions.ocr)
            #expect(embeddings.map(\.id) == ["a"])
            #expect(text.map(\.assetID) == ["a"])

            fixture.processor.release("b", stage: .embedding)
            try await fixture.waitUntilFinished()
            #expect(fixture.store.summary.completeCount == 2)
        }
    }

    @Test
    func pauseDuringOCRPreservesEmbeddingAndResumesOnlyTheIncompleteStage() async throws {
        try await withIndexingFixture { fixture in
            fixture.processor.holdNext("a", stage: .ocr)
            try await fixture.prepare([indexingPhoto("a")])
            fixture.store.start()
            try await indexingEventually { fixture.processor.isWaiting("a", stage: .ocr) }

            fixture.store.pause()
            #expect(fixture.store.phase == .pausing)
            #expect(fixture.store.isBusy)
            fixture.processor.release("a", stage: .ocr)
            try await indexingEventually { !fixture.store.isBusy }
            let paused = try #require(try await fixture.database.record(for: "a"))
            #expect(paused.embedding.status == .complete)
            #expect(paused.ocr.status == .pending)
            #expect(fixture.store.phase == .paused)
            #expect(fixture.store.summary.embeddingCount == 1)

            fixture.store.start()
            try await fixture.waitUntilFinished()
            #expect(fixture.processor.embeddingIDs == ["a"])
            #expect(fixture.processor.ocrIDs == ["a", "a"])
            #expect(fixture.store.summary.completeCount == 1)
        }
    }

    @Test
    func cancellingASourceSettlesTheWorkerAndIgnoresItsLateCallback() async throws {
        try await withIndexingFixture { fixture in
            fixture.source.deferredIDs = ["a"]
            try await fixture.prepare([indexingPhoto("a")])
            fixture.store.start()
            try await indexingEventually { fixture.source.requests.count == 1 }
            let oldRequest = fixture.source.requests[0]

            fixture.store.pause()
            try await indexingEventually { !fixture.store.isBusy }
            #expect(fixture.source.cancelled == [oldRequest.id])
            let paused = try #require(try await fixture.database.record(for: "a"))
            #expect(paused.embedding.status == .pending)
            #expect(paused.ocr.status == .pending)

            oldRequest.completion(.source(indexingSource("a")))
            await Task.yield()
            #expect(fixture.processor.embeddingIDs.isEmpty)
            #expect(fixture.store.summary.completeCount == 0)

            fixture.source.deferredIDs = []
            fixture.store.start()
            try await fixture.waitUntilFinished()
            #expect(fixture.source.requests.count == 2)
            #expect(fixture.processor.embeddingIDs == ["a"])
        }
    }

    @Test
    func immediateResumeWaitsForCancelledInferenceToDrainBeforeStartingAnotherWorker() async throws {
        try await withIndexingFixture { fixture in
            fixture.processor.holdNext("a", stage: .embedding)
            try await fixture.prepare([indexingPhoto("a")])
            fixture.store.start()
            try await indexingEventually { fixture.processor.isWaiting("a", stage: .embedding) }

            fixture.store.pause()
            fixture.store.start()
            for _ in 0..<20 { await Task.yield() }
            #expect(fixture.source.requests.count == 1)
            #expect(fixture.processor.embeddingIDs == ["a"])
            #expect(fixture.store.isBusy)

            fixture.processor.release("a", stage: .embedding)
            try await fixture.waitUntilFinished()
            #expect(fixture.processor.embeddingIDs == ["a", "a"])
            #expect(fixture.processor.maximumConcurrentCalls == 1)
            #expect(fixture.store.summary.completeCount == 1)
        }
    }

    @Test
    func foregroundNeedsAFreshSnapshotAndManualPauseSurvivesActivityChanges() async throws {
        try await withIndexingFixture { fixture in
            let photos = [indexingPhoto("a")]
            fixture.source.deferredIDs = ["a"]
            try await fixture.prepare(photos)
            fixture.store.start()
            try await indexingEventually { fixture.source.requests.count == 1 }

            fixture.store.setActive(false)
            try await indexingEventually { !fixture.store.isBusy }
            fixture.store.setActive(true)
            for _ in 0..<20 { await Task.yield() }
            #expect(fixture.source.requests.count == 1)
            #expect(fixture.store.phase == .waitingForLibrary)
            #expect(fixture.store.wantsToRun)

            fixture.store.updatePhotos(photos)
            try await indexingEventually { fixture.source.requests.count == 2 }
            fixture.store.pause()
            try await indexingEventually { !fixture.store.isBusy }
            fixture.store.setActive(false)
            fixture.store.setActive(true)
            fixture.store.updatePhotos(photos)
            try await indexingEventually { !fixture.store.isBusy && fixture.store.phase == .ready }
            #expect(!fixture.store.wantsToRun)
            #expect(fixture.source.requests.count == 2)
        }
    }

    @Test
    func retryRevisitsCloudAndFailedStagesWithoutRepeatingCompletedWork() async throws {
        try await withIndexingFixture { fixture in
            fixture.source.responses["cloud"] = .requiresDownload
            fixture.processor.failNextEmbedding("failed")
            try await fixture.prepare([indexingPhoto("done"), indexingPhoto("cloud"), indexingPhoto("failed")])
            fixture.store.start()
            try await fixture.waitUntilFinished()
            #expect(fixture.store.summary.completeCount == 1)
            #expect(fixture.store.summary.downloadRequiredCount == 1)
            #expect(fixture.store.summary.failedCount == 1)
            #expect(fixture.store.summary.ocrCount == 2)
            let firstRequests = fixture.source.requests.count

            // Ordinary Start does not turn skipped stages into an automatic loop.
            fixture.store.start()
            try await fixture.waitUntilFinished()
            #expect(fixture.source.requests.count == firstRequests)

            fixture.source.responses.removeValue(forKey: "cloud")
            fixture.store.retry()
            try await fixture.waitUntilFinished()
            #expect(fixture.store.summary.completeCount == 3)
            #expect(fixture.store.summary.failedCount == 0)
            #expect(fixture.store.summary.downloadRequiredCount == 0)
            #expect(fixture.source.requests.filter { $0.photo.id == "done" }.count == 1)
            #expect(fixture.processor.embeddingIDs.filter { $0 == "failed" }.count == 2)
            #expect(fixture.processor.ocrIDs.filter { $0 == "failed" }.count == 1)
        }
    }

    @Test
    func revocationDuringInferenceClearsCompletedDataAndRejectsLateResults() async throws {
        try await withIndexingFixture { fixture in
            fixture.processor.holdNext("b", stage: .embedding)
            try await fixture.prepare([indexingPhoto("a"), indexingPhoto("b")])
            fixture.store.start()
            try await indexingEventually { fixture.processor.isWaiting("b", stage: .embedding) }
            #expect(fixture.store.summary.completeCount == 1)

            fixture.accessibleIDs = []
            fixture.store.revokeAccess()
            #expect(fixture.store.summary == .empty)
            #expect(!fixture.store.wantsToRun)
            fixture.processor.release("b", stage: .embedding)
            try await indexingEventually { !fixture.store.isBusy }
            #expect(try await fixture.database.summary() == .empty)
            #expect(try await fixture.database.searchOCR("recipe", version: indexingVersions.ocr).isEmpty)
            #expect(try await fixture.database.embeddings(modelID: indexingVersions.embedding).isEmpty)
            #expect(fixture.store.phase == .waitingForLibrary)
        }
    }

    @Test
    func finalAccessCheckRemovesAnAssetEvenBeforeTheLibraryObserverFires() async throws {
        try await withIndexingFixture { fixture in
            fixture.processor.holdNext("a", stage: .ocr)
            try await fixture.prepare([indexingPhoto("a"), indexingPhoto("b")])
            fixture.store.start()
            try await indexingEventually { fixture.processor.isWaiting("a", stage: .ocr) }

            fixture.accessibleIDs = ["b"]
            fixture.processor.release("a", stage: .ocr)
            try await fixture.waitUntilFinished()
            #expect(try await fixture.database.record(for: "a") == nil)
            #expect(try await fixture.database.record(for: "b")?.ocr.status == .complete)
            let embeddings = try await fixture.database.embeddings(modelID: indexingVersions.embedding)
            #expect(embeddings.map(\.id) == ["b"])
        }
    }

    @Test
    func reducedSnapshotDuringInferencePrunesRemovedPhotosAndIndexesOnlyTheNewSelection() async throws {
        try await withIndexingFixture { fixture in
            fixture.processor.holdNext("a", stage: .embedding)
            try await fixture.prepare([indexingPhoto("a"), indexingPhoto("b")])
            fixture.store.start()
            try await indexingEventually { fixture.processor.isWaiting("a", stage: .embedding) }

            fixture.accessibleIDs = ["b"]
            fixture.store.invalidateLibrary()
            fixture.store.updatePhotos([indexingPhoto("b")])
            #expect(fixture.store.summary == .empty)
            fixture.processor.release("a", stage: .embedding)
            try await fixture.waitUntilFinished()
            #expect(try await fixture.database.record(for: "a") == nil)
            #expect(fixture.store.summary.totalCount == 1)
            #expect(fixture.store.summary.completeCount == 1)
            #expect(fixture.processor.embeddingIDs == ["a", "b"])
            #expect(fixture.processor.maximumConcurrentCalls == 1)
        }
    }

    @Test
    func deniedRelaunchClearsExistingIndexWithoutNeedingModelsOrAPhotoSnapshot() async throws {
        try await withIndexingFixture { fixture in
            try await seedCompletedIndex(fixture.database, photo: indexingPhoto("old"))
            fixture.processor.setVersionsFailure(true)
            fixture.accessibleIDs = []

            fixture.store.revokeAccess()
            fixture.store.setActive(true)
            try await indexingEventually { !fixture.store.isBusy }

            #expect(try await fixture.database.summary() == .empty)
            #expect(fixture.processor.versionsCallCount == 0)
            #expect(fixture.source.requests.isEmpty)
            #expect(fixture.store.phase == .waitingForLibrary)
        }
    }

    @Test
    func modelMetadataFailureStillPrunesPhotosOutsideThePermittedSnapshot() async throws {
        try await withIndexingFixture { fixture in
            try await seedCompletedIndex(fixture.database, photo: indexingPhoto("removed"))
            try await seedCompletedIndex(fixture.database, photo: indexingPhoto("kept"))
            fixture.processor.setVersionsFailure(true)
            fixture.accessibleIDs = ["kept"]
            fixture.store.setActive(true)
            fixture.store.updatePhotos([indexingPhoto("kept")])
            try await indexingEventually { !fixture.store.isBusy && fixture.store.phase == .failed }

            #expect(try await fixture.database.record(for: "removed") == nil)
            #expect(try await fixture.database.record(for: "kept")?.embedding.status == .complete)
            #expect(fixture.store.summary == .empty)
            #expect(fixture.store.message != nil)
            #expect(fixture.source.requests.isEmpty)
        }
    }
}

private let indexingVersions = PhotoIndexVersions(embedding: "clip-indexing-test", ocr: "ocr-indexing-test")

private func indexingPhoto(_ id: String) -> LibraryPhoto {
    LibraryPhoto(id: id, creationDate: nil, modificationDate: nil, pixelWidth: 100, pixelHeight: 100)
}

private func indexingSource(_ id: String) -> PhotoOCRSource {
    PhotoOCRSource(data: Data(id.utf8), orientation: .up)
}

private func indexingEmbedding() throws -> CLIPEmbedding {
    try CLIPEmbedding(rawValues: [1] + Array(repeating: 0, count: 511), modelID: indexingVersions.embedding)
}

private func indexingOCR(_ id: String) -> PhotoOCRResult {
    PhotoOCRResult(lines: [PhotoOCRLine(text: "recipe \(id)", confidence: 0.9,
        boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.2))], revision: 3, languages: ["ru-RU", "en-US"])
}

private func seedCompletedIndex(_ database: PhotoIndexStore, photo: LibraryPhoto) async throws {
    try await database.upsert(photo, versions: indexingVersions)
    let imageTicket = try await database.beginWork(for: photo.id, stage: .embedding)
    let textTicket = try await database.beginWork(for: photo.id, stage: .ocr)
    try await database.saveEmbedding(indexingEmbedding(), for: imageTicket)
    try await database.saveOCR(indexingOCR(photo.id), for: textTicket)
}

private enum IndexingTestError: Error { case timedOut, unavailableVersions }

@MainActor
private func indexingEventually(_ condition: @MainActor () async throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while clock.now < deadline {
        if try await condition() { return }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(2))
    }
    throw IndexingTestError.timedOut
}

@MainActor
private func withIndexingFixture(_ body: (IndexingFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Indexing-\(UUID().uuidString)")
    let fixture = try IndexingFixture(directory: directory)
    do {
        try await body(fixture)
        try await fixture.finish()
        try FileManager.default.removeItem(at: directory)
    } catch {
        try? await fixture.finish()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

@MainActor
private final class IndexingFixture {
    let database: PhotoIndexStore
    let source = IndexingSourceStub()
    let processor = IndexingProcessorStub()
    var accessibleIDs: Set<String> = []
    lazy var store = PhotoIndexingStore(provider: source, processor: processor,
        openStore: { [database] in database },
        isCurrentAndAccessible: { [weak self] in self?.accessibleIDs.contains($0.id) == true })

    init(directory: URL) throws { database = try PhotoIndexStore(directoryURL: directory) }

    func prepare(_ photos: [LibraryPhoto]) async throws {
        accessibleIDs = Set(photos.map(\.id))
        store.setActive(true)
        store.updatePhotos(photos)
        try await indexingEventually { !self.store.isBusy && self.store.phase == .ready }
    }

    func waitUntilFinished() async throws {
        try await indexingEventually { !self.store.isBusy && self.store.phase == .finished }
    }

    func finish() async throws {
        store.pause()
        processor.releaseAll()
        try await indexingEventually { !self.store.isBusy }
        try await database.close()
    }
}

@MainActor
private final class IndexingSourceStub: PhotoOCRSourceProviding {
    struct Request {
        let id: UUID
        let photo: LibraryPhoto
        let completion: @MainActor (PhotoOCRSourceResult) -> Void
    }

    var deferredIDs: Set<String> = []
    var responses: [String: PhotoOCRSourceResult] = [:]
    private(set) var requests: [Request] = []
    private(set) var cancelled: [UUID] = []

    func requestSource(for photo: LibraryPhoto,
                       completion: @escaping @MainActor (PhotoOCRSourceResult) -> Void) -> UUID {
        let id = UUID()
        requests.append(Request(id: id, photo: photo, completion: completion))
        if !deferredIDs.contains(photo.id) {
            completion(responses[photo.id] ?? .source(indexingSource(photo.id)))
        }
        return id
    }

    func cancel(_ requestID: UUID) { cancelled.append(requestID) }
}

@MainActor
private final class IndexingProcessorStub: PhotoIndexProcessing {
    private var heldNext: Set<String> = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var failedNextEmbeddings: Set<String> = []
    private var failsVersions = false
    private var activeCalls = 0
    private(set) var maximumConcurrentCalls = 0
    private(set) var embeddingIDs: [String] = []
    private(set) var ocrIDs: [String] = []
    private(set) var versionsCallCount = 0

    init() { }

    @MainActor func versions() async throws -> PhotoIndexVersions {
        versionsCallCount += 1
        if failsVersions { throw IndexingTestError.unavailableVersions }
        return indexingVersions
    }

    @MainActor func embedding(_ source: PhotoOCRSource) async throws -> CLIPEmbedding {
        let id = String(decoding: source.data, as: UTF8.self)
        embeddingIDs.append(id)
        await enter(id, stage: .embedding)
        defer { activeCalls -= 1 }
        if failedNextEmbeddings.remove(id) != nil { throw PhotoOCRError.invalidImage }
        return try indexingEmbedding()
    }

    @MainActor func recognize(_ source: PhotoOCRSource) async throws -> PhotoOCRResult {
        let id = String(decoding: source.data, as: UTF8.self)
        ocrIDs.append(id)
        await enter(id, stage: .ocr)
        defer { activeCalls -= 1 }
        return indexingOCR(id)
    }

    @MainActor func unload() async { }
    func setVersionsFailure(_ failure: Bool) { failsVersions = failure }
    func failNextEmbedding(_ id: String) { failedNextEmbeddings.insert(id) }
    func holdNext(_ id: String, stage: PhotoIndexStage) { heldNext.insert(key(id, stage)) }
    func isWaiting(_ id: String, stage: PhotoIndexStage) -> Bool { gates[key(id, stage)] != nil }

    func release(_ id: String, stage: PhotoIndexStage) {
        gates.removeValue(forKey: key(id, stage))?.resume()
    }

    func releaseAll() {
        heldNext = []
        let continuations = Array(gates.values)
        gates = [:]
        for continuation in continuations { continuation.resume() }
    }

    private func key(_ id: String, _ stage: PhotoIndexStage) -> String { "\(id)/\(stage.rawValue)" }

    private func enter(_ id: String, stage: PhotoIndexStage) async {
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        let key = key(id, stage)
        if heldNext.remove(key) != nil {
            // Deliberately ignore cancellation like a synchronous model prediction.
            await withCheckedContinuation { gates[key] = $0 }
        }
    }
}
