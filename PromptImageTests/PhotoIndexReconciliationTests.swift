import Foundation
import SQLite3
import Testing
@testable import PromptImage

/// Complete synthetic snapshots exercise pruning without Photos or model resources.
@MainActor
struct PhotoIndexReconciliationTests {
    private let versions = PhotoIndexVersions(embedding: "clip-test-v1", ocr: "vision-test-v1")

    @Test
    func unchangedSnapshotsPreserveResultsAndActiveTicketsWithoutRegisteringNewAssets() async throws {
        try await withStore { store, _ in
            try await store.synchronize([photo("complete"), photo("running")], versions: versions)
            try await complete("complete", in: store)
            let original = try #require(try await store.record(for: "complete"))
            let running = try await store.beginWork(for: "running", stage: .embedding)

            try await store.pruneStaleRecords(matching: [photo("complete"), photo("running"), photo("new")])

            #expect(try await store.record(for: "complete") == original)
            #expect(try await store.record(for: "new") == nil)
            #expect(try await store.embeddings(modelID: versions.embedding).map(\.id) == ["complete"])
            #expect(try await store.searchOCR("recipe", version: versions.ocr).map(\.assetID) == ["complete"])
            try await store.saveEmbedding(embedding(), for: running)
        }
    }

    @Test
    func editsAndDeletionsPruneBothSearchIndexesBeforeAnyModelVersionIsAvailable() async throws {
        try await withStore { store, _ in
            try await store.synchronize([photo("edit"), photo("keep"), photo("remove")], versions: versions)
            for id in ["edit", "keep", "remove"] { try await complete(id, in: store) }
            let before = try #require(try await store.record(for: "edit"))
            let changed = photo("edit", modified: 2)

            // No model versions or processors are needed to remove stale private data.
            try await store.pruneStaleRecords(matching: [changed, photo("keep")])

            #expect(try await store.record(for: "edit") == nil)
            #expect(try await store.record(for: "remove") == nil)
            #expect(try await store.ocr(for: "edit", version: versions.ocr) == nil)
            #expect(try await store.embeddings(modelID: versions.embedding).map(\.id) == ["keep"])
            #expect(try await store.searchOCR("recipe", version: versions.ocr).map(\.assetID) == ["keep"])

            try await store.synchronize([changed, photo("keep")], versions: versions)
            let replacement = try #require(try await store.record(for: "edit"))
            #expect(replacement.photo == changed)
            #expect(replacement.generation != before.generation)
            #expect(replacement.embedding.status == .pending)
            #expect(replacement.ocr.status == .pending)
        }
    }

    @Test
    func explicitContentChangesInvalidateIdenticalMetadataAndRejectOldTickets() async throws {
        try await withStore { store, _ in
            let snapshot = [photo("changed"), photo("keep")]
            try await store.synchronize(snapshot, versions: versions)
            let original = try #require(try await store.record(for: "changed"))
            let oldImage = try await store.beginWork(for: "changed", stage: .embedding)
            let oldText = try await store.beginWork(for: "changed", stage: .ocr)
            try await store.saveOCR(ocr(), for: oldText)
            try await complete("keep", in: store)
            let preserved = try #require(try await store.record(for: "keep"))

            try await store.pruneStaleRecords(matching: snapshot, invalidatedAssetIDs: ["changed", "not-indexed"])

            #expect(try await store.record(for: "changed") == nil)
            #expect(try await store.record(for: "keep") == preserved)
            #expect(try await store.searchOCR("recipe", version: versions.ocr).map(\.assetID) == ["keep"])
            try await store.synchronize(snapshot, versions: versions)
            let replacement = try #require(try await store.record(for: "changed"))
            #expect(replacement.generation != original.generation)
            let current = try await store.beginWork(for: "changed", stage: .embedding)
            await #expect(throws: PhotoIndexError.staleWork) {
                try await store.saveEmbedding(embedding(), for: oldImage)
            }
            await #expect(throws: PhotoIndexError.staleWork) { try await store.saveOCR(ocr(), for: oldText) }
            try await store.saveEmbedding(embedding(), for: current)
        }
    }

    @Test
    func nonincrementalFallbackInvalidatesEveryRecordAndDoesNotQueueNewWork() async throws {
        try await withStore { store, _ in
            try await store.synchronize([photo("complete"), photo("running")], versions: versions)
            try await complete("complete", in: store)
            let old = try await store.beginWork(for: "running", stage: .ocr)

            try await store.pruneStaleRecords(matching: [photo("complete"), photo("running"), photo("new")],
                                               invalidateAll: true)

            #expect(try await store.summary() == .empty)
            #expect(try await store.embeddings(modelID: versions.embedding).isEmpty)
            #expect(try await store.searchOCR("recipe", version: versions.ocr).isEmpty)
            #expect(try await store.recordsNeedingWork().isEmpty)
            await #expect(throws: PhotoIndexError.staleWork) { try await store.saveOCR(ocr(), for: old) }
        }
    }

    @Test(arguments: [false, true])
    func invalidSnapshotsAndChangeIdentifiersLeaveTheIndexUntouched(invalidateAll: Bool) async throws {
        try await withStore { store, _ in
            try await store.synchronize([photo("keep")], versions: versions)
            try await complete("keep", in: store)
            let original = try #require(try await store.record(for: "keep"))
            let badSize = LibraryPhoto(id: "bad-size", creationDate: nil, modificationDate: nil,
                                       pixelWidth: 0, pixelHeight: 10)
            let badDate = LibraryPhoto(id: "bad-date", creationDate: nil,
                modificationDate: Date(timeIntervalSinceReferenceDate: .infinity), pixelWidth: 10, pixelHeight: 10)
            let invalidSnapshots = [[photo("new"), photo("new")], [photo("new"), photo("")],
                                    [photo("new"), badSize], [photo("new"), badDate]]
            for snapshot in invalidSnapshots {
                await #expect(throws: PhotoIndexError.invalidInput) {
                    try await store.pruneStaleRecords(matching: snapshot, invalidatedAssetIDs: ["keep"],
                                                       invalidateAll: invalidateAll)
                }
                #expect(try await store.record(for: "keep") == original)
                #expect(try await store.record(for: "new") == nil)
            }
            await #expect(throws: PhotoIndexError.invalidInput) {
                try await store.pruneStaleRecords(matching: [], invalidatedAssetIDs: [""],
                                                   invalidateAll: invalidateAll)
            }
            #expect(try await store.record(for: "keep") == original)
            #expect(try await store.searchOCR("recipe", version: versions.ocr).map(\.assetID) == ["keep"])
        }
    }

    @Test
    func aFailedDeletionRollsBackPruningAndFTSChanges() async throws {
        try await withStore { store, directory in
            try await store.synchronize([photo("a-first"), photo("z-fail")], versions: versions)
            for id in ["a-first", "z-fail"] { try await complete(id, in: store) }
            let first = try #require(try await store.record(for: "a-first"))
            try withDatabase(in: directory) { database in
                try database.execute("""
                    CREATE TRIGGER test_abort_prune BEFORE DELETE ON photos
                    WHEN old.asset_id = 'z-fail'
                    BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END
                    """)
            }

            await #expect(throws: PhotoIndexError.storage(SQLITE_CONSTRAINT)) {
                try await store.pruneStaleRecords(matching: [])
            }

            #expect(try await store.record(for: "a-first") == first)
            #expect(try await store.record(for: "z-fail")?.embedding.status == .complete)
            #expect(try await store.embeddings(modelID: versions.embedding).map(\.id) == ["a-first", "z-fail"])
            #expect(try await store.searchOCR("recipe", version: versions.ocr).map(\.assetID) == ["a-first", "z-fail"])
        }
    }

    @Test
    func downloadRetryPreservesCompletedFailedPendingAndProcessingStages() async throws {
        try await withStore { store, _ in
            let ids = ["complete", "failed", "pending", "processing"]
            try await store.synchronize(ids.map { photo($0) }, versions: versions)
            let completeImage = try await store.beginWork(for: "complete", stage: .embedding)
            try await store.saveEmbedding(embedding(), for: completeImage)
            let failed = try await store.beginWork(for: "failed", stage: .embedding)
            try await store.fail(failed, with: .invalidImage)
            let running = try await store.beginWork(for: "processing", stage: .embedding)
            for id in ids {
                let cloud = try await store.beginWork(for: id, stage: .ocr)
                try await store.markRequiresDownload(cloud)
            }

            try await store.retryDownloads()

            for id in ids { #expect(try await store.record(for: id)?.ocr.status == .pending) }
            #expect(try await store.record(for: "complete")?.embedding.status == .complete)
            #expect(try await store.record(for: "failed")?.embedding.status == .failed)
            #expect(try await store.record(for: "failed")?.embedding.failure == .invalidImage)
            #expect(try await store.record(for: "pending")?.embedding.status == .pending)
            #expect(try await store.record(for: "processing")?.embedding.status == .processing)
            #expect(try await store.embeddings(modelID: versions.embedding).map(\.id) == ["complete"])
            // Retrying iCloud originals does not revoke another stage's active ticket.
            try await store.saveEmbedding(embedding(), for: running)
            let newFailure = try await store.beginWork(for: "failed", stage: .ocr)
            try await store.fail(newFailure, with: .processingFailed)
            let text = try await store.beginWork(for: "complete", stage: .ocr)
            try await store.saveOCR(ocr(), for: text)

            try await store.retryDownloads()

            #expect(try await store.record(for: "failed")?.ocr.failure == .processingFailed)
            #expect(try await store.searchOCR("recipe", version: versions.ocr).map(\.assetID) == ["complete"])
        }
    }

    private func photo(_ id: String, modified: TimeInterval = 1) -> LibraryPhoto {
        LibraryPhoto(id: id, creationDate: Date(timeIntervalSinceReferenceDate: 0.0000001),
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
            .appendingPathComponent("PhotoIndexReconciliationTests-\(UUID().uuidString)", isDirectory: true)
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
