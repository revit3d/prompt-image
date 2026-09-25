import Foundation
import SQLite3
import Testing
@testable import PromptImage

/// Real SQLite files and synthetic content exercise persistence without accessing Photos.
@MainActor
struct PhotoIndexStoreTests {
    private let versions = PhotoIndexVersions(embedding: "clip-test-v1", ocr: "vision-test-v1")

    @Test
    func registeringUnchangedPhotoPreservesItsIdentityAndCompletedWork() async throws {
        try await withStore { store, _ in
            let original = photo("asset")
            let fresh = try await store.upsert(original, versions: versions)
            #expect(fresh.photo == original)
            #expect(fresh.embedding.status == .pending)
            #expect(fresh.ocr.status == .pending)
            #expect(fresh.embedding.version == versions.embedding)
            #expect(fresh.ocr.version == versions.ocr)

            let work = try await store.beginWork(for: original.id, stage: .embedding)
            try await store.saveEmbedding(embedding(), for: work)
            let unchanged = try await store.upsert(original, versions: versions)
            #expect(unchanged.generation == fresh.generation)
            #expect(unchanged.embedding.status == .complete)
            #expect(unchanged.ocr.status == .pending)
            #expect(try await store.embeddings(modelID: versions.embedding).map(\.id) == [original.id])
            #expect(try await store.record(for: "unknown") == nil)
        }
    }

    @Test
    func completedEmbeddingAndStructuredOCRSurviveReopening() async throws {
        try await withStore { store, directory in
            // Shifting this tiny timestamp to the Unix epoch and back loses precision,
            // which would falsely treat an unchanged PhotoKit snapshot as an edit.
            let original = LibraryPhoto(id: "asset",
                creationDate: Date(timeIntervalSinceReferenceDate: 0.0000001),
                modificationDate: Date(timeIntervalSinceReferenceDate: -0.0000001),
                pixelWidth: 1_000, pixelHeight: 2_000)
            let record = try await store.upsert(original, versions: versions)
            let vector = try embedding()
            let recognized = ocr("Рецепт блинов", "Two eggs; 200 ml milk")
            let imageWork = try await store.beginWork(for: original.id, stage: .embedding)
            let textWork = try await store.beginWork(for: original.id, stage: .ocr)
            try await store.saveEmbedding(vector, for: imageWork)
            try await store.saveOCR(recognized, for: textWork)
            try await store.close()

            let reopened = try PhotoIndexStore(directoryURL: directory)
            do {
                let restored = try #require(try await reopened.record(for: original.id))
                #expect(restored.photo == original)
                #expect(restored.generation == record.generation)
                #expect(restored.embedding.status == .complete)
                #expect(restored.ocr.status == .complete)
                let unchanged = try await reopened.upsert(original, versions: versions)
                #expect(unchanged == restored)
                #expect(try await reopened.ocr(for: original.id, version: versions.ocr) == recognized)
                let vectors = try await reopened.embeddings(modelID: versions.embedding)
                #expect(vectors.map(\.id) == [original.id])
                #expect(vectors.first?.embedding == vector)
                #expect(try await reopened.searchOCR("блинов eggs", version: versions.ocr)
                    .map(\.assetID) == [original.id])
                #expect(try await reopened.recordsNeedingWork().isEmpty)
                try await reopened.close()
            } catch {
                try? await reopened.close()
                throw error
            }
        }
    }

    @Test
    func reopeningRecoversInterruptedStageWithoutRepeatingCompletedStage() async throws {
        try await withStore { store, directory in
            _ = try await store.upsert(photo("asset"), versions: versions)
            let imageWork = try await store.beginWork(for: "asset", stage: .embedding)
            try await store.saveEmbedding(embedding(), for: imageWork)
            let interrupted = try await store.beginWork(for: "asset", stage: .ocr)
            try await store.close()

            let reopened = try PhotoIndexStore(directoryURL: directory)
            do {
                let record = try #require(try await reopened.record(for: "asset"))
                #expect(record.embedding.status == .complete)
                #expect(record.ocr.status == .pending)
                #expect(try await reopened.recordsNeedingWork().map(\.photo.id) == ["asset"])
                await #expect(throws: PhotoIndexError.staleWork) {
                    try await reopened.saveOCR(ocr("obsolete"), for: interrupted)
                }
                let resumed = try await reopened.beginWork(for: "asset", stage: .ocr)
                try await reopened.saveOCR(ocr("current"), for: resumed)
                #expect(try await reopened.ocr(for: "asset", version: versions.ocr)?.text == "current")
                try await reopened.close()
            } catch {
                try? await reopened.close()
                throw error
            }
        }
    }

    @Test
    func changedPhotoInvalidatesBothStagesAndRejectsPreviousWork() async throws {
        try await withStore { store, _ in
            let first = try await store.upsert(photo("asset"), versions: versions)
            let imageWork = try await store.beginWork(for: "asset", stage: .embedding)
            let textWork = try await store.beginWork(for: "asset", stage: .ocr)
            try await store.saveOCR(ocr("old recipe"), for: textWork)

            let changed = photo("asset", modified: 2)
            let replacement = try await store.upsert(changed, versions: versions)
            #expect(replacement.photo == changed)
            #expect(replacement.generation != first.generation)
            #expect(replacement.embedding.status == .pending)
            #expect(replacement.ocr.status == .pending)
            #expect(try await store.ocr(for: "asset", version: versions.ocr) == nil)
            #expect(try await store.searchOCR("recipe", version: versions.ocr).isEmpty)
            await #expect(throws: PhotoIndexError.staleWork) {
                try await store.saveEmbedding(embedding(), for: imageWork)
            }
            await #expect(throws: PhotoIndexError.staleWork) {
                try await store.saveOCR(ocr("old recipe"), for: textWork)
            }
        }
    }

    @Test
    func modelAndOCRVersionChangesInvalidateOnlyTheirOwnStage() async throws {
        try await withStore { store, _ in
            let original = photo("asset")
            _ = try await store.upsert(original, versions: versions)
            let oldImage = try await store.beginWork(for: original.id, stage: .embedding)
            let text = try await store.beginWork(for: original.id, stage: .ocr)
            let nextImageVersions = PhotoIndexVersions(embedding: "clip-test-v2", ocr: versions.ocr)
            let changedImage = try await store.upsert(original, versions: nextImageVersions)
            #expect(changedImage.embedding.status == .pending)
            #expect(changedImage.ocr.status == .processing)
            await #expect(throws: PhotoIndexError.staleWork) {
                try await store.saveEmbedding(embedding(), for: oldImage)
            }
            try await store.saveOCR(ocr("preserved text"), for: text)

            let newImage = try await store.beginWork(for: original.id, stage: .embedding)
            let nextBothVersions = PhotoIndexVersions(embedding: nextImageVersions.embedding, ocr: "vision-test-v2")
            let changedText = try await store.upsert(original, versions: nextBothVersions)
            #expect(changedText.embedding.status == .processing)
            #expect(changedText.ocr.status == .pending)
            #expect(try await store.ocr(for: original.id, version: versions.ocr) == nil)
            #expect(try await store.searchOCR("preserved", version: versions.ocr).isEmpty)
            try await store.saveEmbedding(embedding(modelID: nextBothVersions.embedding), for: newImage)
            #expect(try await store.embeddings(modelID: versions.embedding).isEmpty)
            #expect(try await store.embeddings(modelID: nextBothVersions.embedding).map(\.id) == [original.id])
        }
    }

    @Test
    func cancellationRotatesAttemptAndLateCallbacksCannotAffectRetry() async throws {
        try await withStore { store, _ in
            _ = try await store.upsert(photo("asset"), versions: versions)
            let cancelled = try await store.beginWork(for: "asset", stage: .ocr)
            let cleanup = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await store.cancel(cancelled)
            }
            try await cleanup.value
            #expect(try await store.record(for: "asset")?.ocr.status == .pending)
            let current = try await store.beginWork(for: "asset", stage: .ocr)
            #expect(current.attemptID != cancelled.attemptID)
            await #expect(throws: PhotoIndexError.staleWork) {
                try await store.saveOCR(ocr("late text"), for: cancelled)
            }
            await #expect(throws: PhotoIndexError.staleWork) { try await store.cancel(cancelled) }
            await #expect(throws: PhotoIndexError.staleWork) { try await store.markRequiresDownload(cancelled) }
            await #expect(throws: PhotoIndexError.staleWork) {
                try await store.fail(cancelled, with: .processingFailed)
            }
            #expect(try await store.record(for: "asset")?.ocr.status == .processing)
            try await store.saveOCR(ocr("accepted text"), for: current)
            await #expect(throws: PhotoIndexError.staleWork) {
                try await store.saveOCR(ocr("duplicate callback"), for: current)
            }
            #expect(try await store.ocr(for: "asset", version: versions.ocr)?.text == "accepted text")
        }
    }

    @Test(arguments: [false, true])
    func deletingOrClearingThenReaddingSameAssetRejectsOldTickets(clearAll: Bool) async throws {
        try await withStore { store, _ in
            let original = photo("same-id")
            let first = try await store.upsert(original, versions: versions)
            let oldWork = try await store.beginWork(for: original.id, stage: .embedding)
            if clearAll {
                try await store.clear()
            } else {
                try await store.remove(assetIDs: [original.id, "missing-id"])
            }
            #expect(try await store.record(for: original.id) == nil)
            let replacement = try await store.upsert(original, versions: versions)
            #expect(replacement.generation != first.generation)
            let current = try await store.beginWork(for: original.id, stage: .embedding)
            await #expect(throws: PhotoIndexError.staleWork) {
                try await store.saveEmbedding(embedding(), for: oldWork)
            }
            try await store.saveEmbedding(embedding(), for: current)
            #expect(try await store.record(for: original.id)?.embedding.status == .complete)
        }
    }

    @Test
    func completedAndProcessingStagesCannotBeStartedAgain() async throws {
        try await withStore { store, _ in
            _ = try await store.upsert(photo("asset"), versions: versions)
            let work = try await store.beginWork(for: "asset", stage: .ocr)
            await #expect(throws: PhotoIndexError.invalidTransition) {
                try await store.beginWork(for: "asset", stage: .ocr)
            }
            try await store.saveOCR(ocr(), for: work)
            await #expect(throws: PhotoIndexError.invalidTransition) {
                try await store.beginWork(for: "asset", stage: .ocr)
            }
            #expect(try await store.record(for: "asset")?.ocr.status == .complete)
            let empty = try #require(try await store.ocr(for: "asset", version: versions.ocr))
            #expect(empty.lines.isEmpty)
            #expect(empty.revision == 3)
            #expect(try await store.searchOCR("anything", version: versions.ocr).isEmpty)
        }
    }

    @Test
    func localOnlyQueueCanRetryDownloadRequiredStageAndKeepsOtherStageIndependent() async throws {
        try await withStore { store, _ in
            _ = try await store.upsert(photo("asset"), versions: versions)
            let imageWork = try await store.beginWork(for: "asset", stage: .embedding)
            try await store.markRequiresDownload(imageWork)
            #expect(try await store.record(for: "asset")?.embedding.status == .requiresDownload)
            #expect(try await store.recordsNeedingWork().map(\.photo.id) == ["asset"])

            let textWork = try await store.beginWork(for: "asset", stage: .ocr)
            try await store.markRequiresDownload(textWork)
            #expect(try await store.recordsNeedingWork().isEmpty)
            let retry = try await store.beginWork(for: "asset", stage: .embedding)
            await #expect(throws: PhotoIndexError.staleWork) {
                try await store.saveEmbedding(embedding(), for: imageWork)
            }
            try await store.saveEmbedding(embedding(), for: retry)
            let record = try #require(try await store.record(for: "asset"))
            #expect(record.embedding.status == .complete)
            #expect(record.ocr.status == .requiresDownload)
        }
    }

    @Test
    func failuresStoreSafeCodesAndRequireExplicitRetry() async throws {
        try await withStore { store, _ in
            _ = try await store.upsert(photo("asset"), versions: versions)
            let imageWork = try await store.beginWork(for: "asset", stage: .embedding)
            try await store.fail(imageWork, with: .modelUnavailable)
            #expect(try await store.record(for: "asset")?.embedding.failure == .modelUnavailable)
            #expect(try await store.recordsNeedingWork().map(\.photo.id) == ["asset"])

            let textWork = try await store.beginWork(for: "asset", stage: .ocr)
            try await store.fail(textWork, with: .sourceUnavailable)
            #expect(try await store.record(for: "asset")?.ocr.status == .failed)
            #expect(try await store.record(for: "asset")?.ocr.failure == .sourceUnavailable)
            #expect(try await store.recordsNeedingWork().isEmpty)
            let retry = try await store.beginWork(for: "asset", stage: .ocr)
            #expect(retry.attemptID != textWork.attemptID)
            #expect(try await store.record(for: "asset")?.ocr.failure == nil)
            await #expect(throws: PhotoIndexError.staleWork) {
                try await store.fail(textWork, with: .processingFailed)
            }
            try await store.saveOCR(ocr("retry succeeded"), for: retry)
            #expect(try await store.record(for: "asset")?.ocr.status == .complete)
            #expect(try await store.record(for: "asset")?.embedding.failure == .modelUnavailable)
        }
    }

    @Test
    func fullTextSearchUsesLiteralCaseInsensitiveRussianAndEnglishTerms() async throws {
        try await withStore { store, _ in
            try await saveText("recipe", lines: ["Рецепт блинов", "PANCAKES молоко"], in: store)
            try await saveText("english", lines: ["pancakes sugar"], in: store)
            try await saveText("operators", lines: ["cat OR dog NEAR"], in: store)

            let russian = try await store.searchOCR("РЕЦЕПТ, молоко!", version: versions.ocr)
            #expect(russian.map(\.assetID) == ["recipe"])
            #expect(russian.first?.text == "Рецепт блинов\nPANCAKES молоко")
            #expect(russian.allSatisfy { $0.rank.isFinite })
            #expect(Set(try await store.searchOCR("pancakes", version: versions.ocr).map(\.assetID))
                == Set(["recipe", "english"]))
            #expect(try await store.searchOCR("cat OR dog", version: versions.ocr).map(\.assetID)
                == ["operators"])
            #expect(try await store.searchOCR("cat OR sugar", version: versions.ocr).isEmpty)
            #expect(try await store.searchOCR("NEAR(cat dog)", version: versions.ocr).map(\.assetID)
                == ["operators"])
            #expect(try await store.searchOCR("\" OR *", version: versions.ocr).map(\.assetID)
                == ["operators"])
            #expect(try await store.searchOCR("'; DROP TABLE photos; --", version: versions.ocr).isEmpty)
            #expect(try await store.searchOCR("блин", version: versions.ocr).isEmpty)
            for query in ["", " \n\t", "* + () \" : -"] {
                #expect(try await store.searchOCR(query, version: versions.ocr).isEmpty)
            }
            #expect(try await store.searchOCR("pancakes", version: "other-version").isEmpty)
        }
    }

    @Test
    func replacedDeletedAndClearedTextDisappearsFromSearch() async throws {
        try await withStore { store, _ in
            try await saveText("replace", lines: ["obsolete recipe"], in: store)
            try await saveText("keep", lines: ["shared recipe"], in: store)
            _ = try await store.upsert(photo("replace", modified: 2), versions: versions)
            #expect(try await store.searchOCR("obsolete", version: versions.ocr).isEmpty)
            let work = try await store.beginWork(for: "replace", stage: .ocr)
            try await store.saveOCR(ocr("new instructions"), for: work)
            #expect(try await store.searchOCR("instructions", version: versions.ocr).map(\.assetID) == ["replace"])
            #expect(try await store.searchOCR("recipe", version: versions.ocr).map(\.assetID) == ["keep"])
            try await store.remove(assetIDs: ["replace"])
            #expect(try await store.searchOCR("instructions", version: versions.ocr).isEmpty)
            try await store.clear()
            #expect(try await store.searchOCR("recipe", version: versions.ocr).isEmpty)
            #expect(try await store.ocr(for: "keep", version: versions.ocr) == nil)
            #expect(try await store.recordsNeedingWork().isEmpty)
        }
    }

    @Test
    func embeddingAndPendingPagesHaveStableAssetOrderAndFilterVersions() async throws {
        try await withStore { store, _ in
            for id in ["c", "a", "b"] {
                _ = try await store.upsert(photo(id), versions: versions)
                let work = try await store.beginWork(for: id, stage: .embedding)
                try await store.saveEmbedding(embedding(), for: work)
            }
            let other = PhotoIndexVersions(embedding: "another-model", ocr: versions.ocr)
            _ = try await store.upsert(photo("foreign"), versions: other)
            let work = try await store.beginWork(for: "foreign", stage: .embedding)
            try await store.saveEmbedding(embedding(modelID: other.embedding), for: work)

            #expect(try await store.embeddings(modelID: versions.embedding, limit: 2).map(\.id) == ["a", "b"])
            #expect(try await store.embeddings(modelID: versions.embedding, afterID: "b", limit: 2).map(\.id) == ["c"])
            #expect(try await store.embeddings(modelID: versions.embedding, afterID: "c").isEmpty)
            #expect(try await store.embeddings(modelID: other.embedding).map(\.id) == ["foreign"])
            #expect(try await store.recordsNeedingWork(limit: 2).map(\.photo.id) == ["a", "b"])
            #expect(try await store.recordsNeedingWork(afterID: "b", limit: 2).map(\.photo.id) == ["c", "foreign"])

            for id in ["a", "b", "c", "foreign"] {
                _ = try await store.beginWork(for: id, stage: .ocr)
            }
            #expect(try await store.recordsNeedingWork().isEmpty)
        }
    }

    @Test
    func invalidInputLeavesValidDataAndActiveWorkIntact() async throws {
        try await withStore { store, _ in
            let original = photo("asset")
            _ = try await store.upsert(original, versions: versions)
            let work = try await store.beginWork(for: original.id, stage: .embedding)
            await #expect(throws: PhotoIndexError.invalidInput) {
                try await store.saveEmbedding(embedding(modelID: "wrong-model"), for: work)
            }
            #expect(try await store.record(for: original.id)?.embedding.status == .processing)
            await #expect(throws: PhotoIndexError.invalidInput) {
                try await store.upsert(photo(""), versions: versions)
            }
            await #expect(throws: PhotoIndexError.invalidInput) {
                try await store.upsert(original, versions: .init(embedding: "", ocr: versions.ocr))
            }
            #expect(try await store.record(for: original.id)?.photo == original)
            try await store.saveEmbedding(embedding(), for: work)
            #expect(try await store.embeddings(modelID: versions.embedding).map(\.id) == [original.id])

            for limit in [-1, 0] {
                await #expect(throws: PhotoIndexError.invalidInput) {
                    try await store.recordsNeedingWork(limit: limit)
                }
                await #expect(throws: PhotoIndexError.invalidInput) {
                    try await store.embeddings(modelID: versions.embedding, limit: limit)
                }
                await #expect(throws: PhotoIndexError.invalidInput) {
                    try await store.searchOCR("recipe", version: versions.ocr, limit: limit)
                }
            }
        }
    }

    @Test
    func failedTextInsertionRollsBackPayloadAndStatusAndAllowsSameAttemptToRetry() async throws {
        try await withStore { store, directory in
            _ = try await store.upsert(photo("asset"), versions: versions)
            let work = try await store.beginWork(for: "asset", stage: .ocr)
            try withDatabase(in: directory) { database in
                try database.execute("""
                    CREATE TRIGGER test_abort_text BEFORE INSERT ON ocr_text BEGIN
                        SELECT RAISE(ABORT, 'synthetic failure');
                    END
                    """)
            }
            await #expect(throws: PhotoIndexError.storage(SQLITE_CONSTRAINT)) {
                try await store.saveOCR(ocr("atomic result"), for: work)
            }
            #expect(try await store.record(for: "asset")?.ocr.status == .processing)
            #expect(try await store.ocr(for: "asset", version: versions.ocr) == nil)
            #expect(try await store.searchOCR("atomic", version: versions.ocr).isEmpty)

            try withDatabase(in: directory) { try $0.execute("DROP TRIGGER test_abort_text") }
            try await store.saveOCR(ocr("atomic result"), for: work)
            #expect(try await store.record(for: "asset")?.ocr.status == .complete)
            #expect(try await store.searchOCR("atomic", version: versions.ocr).map(\.assetID) == ["asset"])
        }
    }

    @Test(arguments: PhotoIndexStage.allCases)
    func malformedStoredPayloadIsRejectedInsteadOfReturnedAsAResult(stage: PhotoIndexStage) async throws {
        try await withStore { store, directory in
            _ = try await store.upsert(photo("asset"), versions: versions)
            let imageWork = try await store.beginWork(for: "asset", stage: .embedding)
            let textWork = try await store.beginWork(for: "asset", stage: .ocr)
            try await store.saveEmbedding(embedding(), for: imageWork)
            try await store.saveOCR(ocr("valid text"), for: textWork)
            try await store.close()
            try withDatabase(in: directory) { database in
                let damaged = stage == .embedding ? Data(repeating: 0, count: 2_048) : Data("{".utf8)
                try database.execute("UPDATE stages SET payload = ? WHERE kind = ?",
                                     [.blob(damaged), .text(stage.rawValue)])
            }

            let reopened = try PhotoIndexStore(directoryURL: directory)
            do {
                if stage == .embedding {
                    await #expect(throws: PhotoIndexError.invalidStoredData) {
                        try await reopened.embeddings(modelID: versions.embedding)
                    }
                    #expect(try await reopened.ocr(for: "asset", version: versions.ocr)?.text == "valid text")
                } else {
                    await #expect(throws: PhotoIndexError.invalidStoredData) {
                        try await reopened.ocr(for: "asset", version: versions.ocr)
                    }
                    #expect(try await reopened.embeddings(modelID: versions.embedding).map(\.id) == ["asset"])
                }
                try await reopened.close()
            } catch {
                try? await reopened.close()
                throw error
            }
        }
    }

    @Test(arguments: [999, -1])
    func unsupportedSchemaIsRefusedWithoutReplacingExistingData(version: Int) async throws {
        try await withStore { store, directory in
            try await saveText("asset", lines: ["retained text"], in: store)
            try await store.close()
            try withDatabase(in: directory) { try $0.execute("PRAGMA user_version = \(version)") }
            let expected: PhotoIndexError = version < 0 ? .invalidDatabase : .unsupportedSchema(version)
            #expect(throws: expected) {
                try PhotoIndexStore(directoryURL: directory)
            }
            try withDatabase(in: directory) { database in
                let storedVersion = try database.query("PRAGMA user_version")
                let storedText = try database.query("SELECT text FROM ocr_text")
                #expect(storedVersion == [[.integer(Int64(version))]])
                #expect(storedText == [[.text("retained text")]])
            }
        }
    }

    @Test
    func closedStoreRejectsUseAndIndexDirectoryIsExcludedFromBackup() async throws {
        try await withStore { store, directory in
            _ = try await store.upsert(photo("asset"), versions: versions)
            let resources = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(resources.isExcludedFromBackup == true)
            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            let fileAttributes = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("index.sqlite").path)
            #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            try await store.close()
            try await store.close()
            await #expect(throws: PhotoIndexError.closed) { try await store.record(for: "asset") }
        }
    }

    private func photo(_ id: String, modified: TimeInterval = 1) -> LibraryPhoto {
        LibraryPhoto(id: id, creationDate: Date(timeIntervalSince1970: 0),
                     modificationDate: Date(timeIntervalSince1970: modified),
                     pixelWidth: 1_000, pixelHeight: 2_000)
    }

    private func embedding(modelID: String = "clip-test-v1") throws -> CLIPEmbedding {
        try CLIPEmbedding(rawValues: [1] + Array(repeating: 0, count: 511), modelID: modelID)
    }

    private func ocr(_ lines: String...) -> PhotoOCRResult { ocr(lines: lines) }

    private func ocr(lines: [String]) -> PhotoOCRResult {
        PhotoOCRResult(lines: lines.enumerated().map { index, text in
            PhotoOCRLine(text: text, confidence: 0.9,
                         boundingBox: CGRect(x: 0.1, y: 0.8 - Double(index) * 0.1, width: 0.8, height: 0.05))
        }, revision: 3, languages: ["ru-RU", "en-US"])
    }

    private func saveText(_ id: String, lines: [String], in store: PhotoIndexStore) async throws {
        _ = try await store.upsert(photo(id), versions: versions)
        let work = try await store.beginWork(for: id, stage: .ocr)
        try await store.saveOCR(ocr(lines: lines), for: work)
    }

    private func withStore(_ body: (PhotoIndexStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoIndexStoreTests-\(UUID().uuidString)", isDirectory: true)
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

    /// A short-lived connection injects storage faults while the actor is idle, or
    /// after closing it; this does not create a second PhotoIndexStore owner.
    private func withDatabase(in directory: URL, _ body: (SQLiteConnection) throws -> Void) throws {
        let connection = try SQLiteConnection(url: directory.appendingPathComponent("index.sqlite"))
        defer { try? connection.close() }
        try body(connection)
    }
}
