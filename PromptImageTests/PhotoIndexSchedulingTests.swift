import Foundation
import SQLite3
import Testing
@testable import PromptImage

/// The scheduler uses real transactions with synthetic assets; no Photos access.
@MainActor
struct PhotoIndexSchedulingTests {
    private let versions = PhotoIndexVersions(embedding: "clip-test-v1", ocr: "vision-test-v1")

    @Test
    func synchronizationRemovesMissingAssetsAndInvalidatesEditsWhilePreservingUnchangedResults() async throws {
        try await withStore { store, _ in
            try await store.synchronize([photo("keep"), photo("edit"), photo("remove")], versions: versions)
            for id in ["keep", "edit", "remove"] { try await complete(id, in: store) }
            let kept = try #require(try await store.record(for: "keep"))
            let edited = try #require(try await store.record(for: "edit"))

            try await store.synchronize([photo("keep"), photo("edit", modified: 2), photo("new")], versions: versions)

            #expect(try await store.record(for: "keep") == kept)
            #expect(try await store.record(for: "remove") == nil)
            let replacement = try #require(try await store.record(for: "edit"))
            #expect(replacement.generation != edited.generation)
            #expect(replacement.embedding.status == .pending)
            #expect(replacement.ocr.status == .pending)
            #expect(try await store.embeddings(modelID: versions.embedding).map(\.id) == ["keep"])
            #expect(try await store.searchOCR("recipe", version: versions.ocr).map(\.assetID) == ["keep"])
            #expect(try await store.recordsNeedingWork().map(\.photo.id) == ["edit", "new"])
        }
    }

    @Test(arguments: PhotoIndexStage.allCases)
    func synchronizationInvalidatesOnlyTheChangedPipeline(stage: PhotoIndexStage) async throws {
        try await withStore { store, _ in
            try await store.synchronize([photo("asset")], versions: versions)
            try await complete("asset", in: store)
            let original = try #require(try await store.record(for: "asset"))
            let changed = PhotoIndexVersions(
                embedding: stage == .embedding ? "clip-test-v2" : versions.embedding,
                ocr: stage == .ocr ? "vision-test-v2" : versions.ocr)

            try await store.synchronize([photo("asset")], versions: changed)

            let current = try #require(try await store.record(for: "asset"))
            #expect(current.generation == original.generation)
            #expect(current.embedding.status == (stage == .embedding ? .pending : .complete))
            #expect(current.ocr.status == (stage == .ocr ? .pending : .complete))
            #expect(try await store.searchOCR("recipe", version: versions.ocr).isEmpty == (stage == .ocr))
            #expect(try await store.embeddings(modelID: versions.embedding).isEmpty == (stage == .embedding))
        }
    }

    @Test
    func synchronizationRollsBackDeletionsEditsAndTextWhenAnyInsertionFails() async throws {
        try await withStore { store, directory in
            try await store.synchronize([photo("edit"), photo("remove")], versions: versions)
            for id in ["edit", "remove"] { try await complete(id, in: store) }
            let original = try #require(try await store.record(for: "edit"))
            try withDatabase(in: directory) { database in
                try database.execute("""
                    CREATE TRIGGER test_abort_snapshot BEFORE INSERT ON photos
                    WHEN new.asset_id = 'fail'
                    BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END
                    """)
            }

            await #expect(throws: PhotoIndexError.storage(SQLITE_CONSTRAINT)) {
                try await store.synchronize([photo("edit", modified: 2), photo("fail")], versions: versions)
            }

            #expect(try await store.record(for: "edit") == original)
            #expect(try await store.record(for: "remove")?.embedding.status == .complete)
            #expect(try await store.record(for: "fail") == nil)
            #expect(try await store.embeddings(modelID: versions.embedding).map(\.id) == ["edit", "remove"])
            #expect(try await store.searchOCR("recipe", version: versions.ocr).map(\.assetID) == ["edit", "remove"])
        }
    }

    @Test
    func invalidAndDuplicateSnapshotsDoNotMutateTheExistingIndex() async throws {
        try await withStore { store, _ in
            try await store.synchronize([photo("keep")], versions: versions)
            try await complete("keep", in: store)
            let original = try #require(try await store.record(for: "keep"))
            for invalid in [[photo("new"), photo("new")], [photo("new"), photo("")]] {
                await #expect(throws: PhotoIndexError.invalidInput) {
                    try await store.synchronize(invalid, versions: versions)
                }
                #expect(try await store.record(for: "keep") == original)
                #expect(try await store.record(for: "new") == nil)
            }
            await #expect(throws: PhotoIndexError.invalidInput) {
                try await store.synchronize([], versions: .init(embedding: "", ocr: versions.ocr))
            }
            #expect(try await store.record(for: "keep") == original)
        }
    }

    @Test
    func summariesCountPhotosAndExplicitRetryPreservesSuccessfulAndRunningStages() async throws {
        try await withStore { store, _ in
            #expect(try await store.summary() == .empty)
            try await store.synchronize(["complete", "partial", "cloud", "mixed", "running"].map { photo($0) },
                                        versions: versions)
            try await complete("complete", in: store)
            let image = try await store.beginWork(for: "partial", stage: .embedding)
            try await store.saveEmbedding(embedding(), for: image)
            let text = try await store.beginWork(for: "partial", stage: .ocr)
            try await store.fail(text, with: .processingFailed)
            for stage in PhotoIndexStage.allCases {
                let work = try await store.beginWork(for: "cloud", stage: stage)
                try await store.markRequiresDownload(work)
            }
            let mixedImage = try await store.beginWork(for: "mixed", stage: .embedding)
            try await store.fail(mixedImage, with: .sourceUnavailable)
            let mixedText = try await store.beginWork(for: "mixed", stage: .ocr)
            try await store.markRequiresDownload(mixedText)
            let running = try await store.beginWork(for: "running", stage: .embedding)
            let before = try await store.summary()
            #expect(before == PhotoIndexSummary(totalCount: 5, completeCount: 1, embeddingCount: 2,
                ocrCount: 1, pendingCount: 1, downloadRequiredCount: 2, failedCount: 2))

            try await store.retryIncomplete()

            #expect(try await store.summary() == PhotoIndexSummary(totalCount: 5, completeCount: 1,
                embeddingCount: 2, ocrCount: 1, pendingCount: 4, downloadRequiredCount: 0, failedCount: 0))
            #expect(try await store.record(for: "partial")?.ocr.failure == nil)
            #expect(try await store.record(for: "running")?.embedding.status == .processing)
            #expect(try await store.embeddings(modelID: versions.embedding).map(\.id) == ["complete", "partial"])
            #expect(try await store.searchOCR("recipe", version: versions.ocr).map(\.assetID) == ["complete"])
            // The in-flight ticket remains valid; retry does not interrupt a worker.
            try await store.saveEmbedding(embedding(), for: running)
        }
    }

    @Test
    func recoveryResetsOnlyInterruptedWorkAndRejectsItsLateCompletion() async throws {
        try await withStore { store, _ in
            try await store.synchronize([photo("asset"), photo("failed")], versions: versions)
            let image = try await store.beginWork(for: "asset", stage: .embedding)
            try await store.saveEmbedding(embedding(), for: image)
            let interrupted = try await store.beginWork(for: "asset", stage: .ocr)
            let failed = try await store.beginWork(for: "failed", stage: .embedding)
            try await store.fail(failed, with: .invalidImage)

            try await store.recoverInterruptedWork()
            try await store.recoverInterruptedWork()

            #expect(try await store.record(for: "asset")?.embedding.status == .complete)
            #expect(try await store.record(for: "asset")?.ocr.status == .pending)
            #expect(try await store.record(for: "failed")?.embedding.failure == .invalidImage)
            await #expect(throws: PhotoIndexError.staleWork) {
                try await store.saveOCR(ocr(), for: interrupted)
            }
            let resumed = try await store.beginWork(for: "asset", stage: .ocr)
            try await store.saveOCR(ocr(), for: resumed)
            #expect(try await store.summary().completeCount == 1)
        }
    }

    @Test
    func retentionPrunesSearchableDataAndTicketsWithoutNeedingModelVersions() async throws {
        try await withStore { store, _ in
            try await store.synchronize([photo("keep"), photo("remove"), photo("processing")], versions: versions)
            try await complete("keep", in: store)
            try await complete("remove", in: store)
            let work = try await store.beginWork(for: "processing", stage: .ocr)

            try await store.retainOnly(assetIDs: ["keep"])

            #expect(try await store.record(for: "remove") == nil)
            #expect(try await store.record(for: "processing") == nil)
            #expect(try await store.embeddings(modelID: versions.embedding).map(\.id) == ["keep"])
            #expect(try await store.searchOCR("recipe", version: versions.ocr).map(\.assetID) == ["keep"])
            await #expect(throws: PhotoIndexError.staleWork) { try await store.saveOCR(ocr(), for: work) }

            try await store.retainOnly(assetIDs: [])

            #expect(try await store.summary() == .empty)
            #expect(try await store.embeddings(modelID: versions.embedding).isEmpty)
            #expect(try await store.searchOCR("recipe", version: versions.ocr).isEmpty)
        }
    }

    @Test
    func emptyPermittedSnapshotClearsTheIndex() async throws {
        try await withStore { store, _ in
            try await store.synchronize([photo("asset")], versions: versions)
            try await complete("asset", in: store)
            try await store.synchronize([], versions: versions)
            #expect(try await store.summary() == .empty)
            #expect(try await store.recordsNeedingWork().isEmpty)
            #expect(try await store.searchOCR("recipe", version: versions.ocr).isEmpty)
        }
    }

    private func photo(_ id: String, modified: TimeInterval = 1) -> LibraryPhoto {
        LibraryPhoto(id: id, creationDate: Date(timeIntervalSinceReferenceDate: 0),
                     modificationDate: Date(timeIntervalSinceReferenceDate: modified),
                     pixelWidth: 1_000, pixelHeight: 2_000)
    }

    private func embedding() throws -> CLIPEmbedding {
        try CLIPEmbedding(rawValues: [1] + Array(repeating: 0, count: 511), modelID: versions.embedding)
    }

    private func ocr() -> PhotoOCRResult {
        PhotoOCRResult(lines: [PhotoOCRLine(text: "recipe", confidence: 0.9,
            boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.1))], revision: 3, languages: ["en-US"])
    }

    private func complete(_ id: String, in store: PhotoIndexStore) async throws {
        let image = try await store.beginWork(for: id, stage: .embedding)
        try await store.saveEmbedding(embedding(), for: image)
        let text = try await store.beginWork(for: id, stage: .ocr)
        try await store.saveOCR(ocr(), for: text)
    }

    private func withStore(_ body: (PhotoIndexStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoIndexSchedulingTests-\(UUID().uuidString)", isDirectory: true)
        let store = try PhotoIndexStore(directoryURL: directory)
        do {
            try await body(store, directory)
            try await store.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await store.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func withDatabase(in directory: URL, _ body: (SQLiteConnection) throws -> Void) throws {
        let connection = try SQLiteConnection(url: directory.appendingPathComponent("index.sqlite"))
        defer { try? connection.close() }
        try body(connection)
    }
}
