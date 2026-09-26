import Foundation
import Testing
@testable import PromptImage

/// Exercises the combined retrieval operation against real temporary SQLite files.
@MainActor
struct PhotoIndexSearchTests {
    private let versions = PhotoIndexVersions(embedding: "search-clip-v1", ocr: "search-ocr-v1")

    @Test
    func textOnlyKeepsBM25OrderMetadataAndCurrentOCRVersion() async throws {
        try await withStore { store, _ in
            let original = LibraryPhoto(id: "concentrated",
                creationDate: Date(timeIntervalSinceReferenceDate: 123),
                modificationDate: Date(timeIntervalSinceReferenceDate: 456),
                pixelWidth: 1_024, pixelHeight: 2_048)
            try await save(original, text: "рецепт рецепт рецепт", in: store)
            try await save(photo("diluted"), text: "рецепт с яйцами молоком маслом мукой", in: store)
            try await save(photo("wrong-visual"), versions: .init(embedding: "old-clip", ocr: versions.ocr),
                text: "рецепт", in: store)
            try await save(photo("wrong-ocr"), versions: .init(embedding: versions.embedding, ocr: "old-ocr"),
                vector: embedding(), text: "рецепт", in: store)
            try await save(photo("visual-only"), vector: embedding(), in: store)

            let expected = try await store.searchOCR("рецепт", version: versions.ocr)
            let matches = try await store.searchText("рецепт", ocrVersion: versions.ocr)

            #expect(matches.map(\.photo.id) == expected.map(\.assetID))
            #expect(matches.map(\.recognizedText) == expected.map { Optional($0.text) })
            #expect(Set(matches.map(\.photo.id)) == ["concentrated", "diluted", "wrong-visual"])
            #expect(matches.first { $0.photo.id == "concentrated" }?.photo == original)
            #expect(matches.allSatisfy { $0.visualSimilarity == nil })
            #expect(try await store.searchText("рецепт", ocrVersion: versions.ocr, limit: 1) == [matches[0]])
        }
    }

    @Test
    func textOnlyUsesLiteralOperatorsAndHandlesPunctuationWithoutVisualFallback() async throws {
        try await withStore { store, _ in
            try await save(photo("literal"), text: "кот OR собака", in: store)
            try await save(photo("both-words"), text: "кот собака", in: store)
            try await save(photo("visual"), vector: embedding(), in: store)

            let matches = try await store.searchText("\"кот\" OR (собака*)", ocrVersion: versions.ocr)
            #expect(matches.map(\.photo.id) == ["literal"])
            #expect(try await store.searchText(" !!!... ", ocrVersion: versions.ocr).isEmpty)
            #expect(try await store.searchText("absent", ocrVersion: versions.ocr).isEmpty)
            await #expect(throws: QueryInputError.empty) {
                try await store.searchText(" \n ", ocrVersion: versions.ocr)
            }
            await #expect(throws: PhotoSearchError.invalidLimit) {
                try await store.searchText("кот", ocrVersion: versions.ocr, limit: 0)
            }
            await #expect(throws: QueryInputError.tooLong) {
                try await store.searchText(String(repeating: "word ", count: 33), ocrVersion: versions.ocr)
            }
        }
    }

    @Test
    func cancelledTextOnlySearchDoesNotDeliverPersistedOCR() async throws {
        try await withStore { store, _ in
            try await save(photo("a"), text: "рецепт", in: store)
            let ocrVersion = versions.ocr
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await store.searchText("рецепт", ocrVersion: ocrVersion)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.searchText("рецепт", ocrVersion: versions.ocr).count == 1)
        }
    }

    @Test
    func savedSearchResultsAndPhotoMetadataSurviveReopeningWithoutReindexing() async throws {
        try await withStore { store, directory in
            let original = LibraryPhoto(id: "both",
                creationDate: Date(timeIntervalSinceReferenceDate: 0.0000001),
                modificationDate: Date(timeIntervalSinceReferenceDate: -0.0000001),
                pixelWidth: 1_024, pixelHeight: 2_048)
            try await save(original, vector: embedding(), text: "Рецепт блинов", in: store)
            try await save(photo("text"), text: "Рецепт из блокнота", in: store)
            let prepared = try query("рецепт", english: "pancake recipe")
            let before = try await store.search(prepared, ocrVersion: versions.ocr)
            #expect(before.first?.photo == original)
            #expect(before.count == 2)
            try await store.close()

            let reopened = try PhotoIndexStore(directoryURL: directory)
            do {
                let after = try await reopened.search(prepared, ocrVersion: versions.ocr)
                #expect(after == before)
                #expect(after.first?.recognizedText == "Рецепт блинов")
                #expect(after.first?.visualSimilarity == 1)
                #expect(try await reopened.record(for: "text")?.embedding.status == .pending)
                #expect(try await reopened.record(for: "text")?.ocr.status == .complete)
                try await reopened.close()
            } catch {
                try? await reopened.close()
                throw error
            }
        }
    }

    @Test
    func completedStagesAreSearchableIndependentlyAndFilterTheirOwnVersions() async throws {
        try await withStore { store, _ in
            try await save(photo("visual-only"), vector: embedding(), in: store)
            try await save(photo("text-only"), text: "рецепт", in: store)
            try await save(photo("wrong-visual"),
                versions: .init(embedding: "old-clip", ocr: versions.ocr),
                vector: embedding(modelID: "old-clip"), text: "рецепт", in: store)
            try await save(photo("wrong-text"),
                versions: .init(embedding: versions.embedding, ocr: "old-ocr"),
                vector: embedding(), text: "рецепт", in: store)
            try await save(photo("both-obsolete"),
                versions: .init(embedding: "old-clip", ocr: "old-ocr"),
                vector: embedding(modelID: "old-clip"), text: "рецепт", in: store)
            _ = try await store.upsert(photo("processing"), versions: versions)
            _ = try await store.beginWork(for: "processing", stage: .embedding)
            _ = try await store.beginWork(for: "processing", stage: .ocr)
            _ = try await store.upsert(photo("incomplete"), versions: versions)
            let failed = try await store.beginWork(for: "incomplete", stage: .embedding)
            try await store.fail(failed, with: .processingFailed)
            let cloud = try await store.beginWork(for: "incomplete", stage: .ocr)
            try await store.markRequiresDownload(cloud)

            let matches = try await store.search(query("рецепт"), ocrVersion: versions.ocr)
            let byID = Dictionary(uniqueKeysWithValues: matches.map { ($0.photo.id, $0) })
            #expect(Set(byID.keys) == ["visual-only", "text-only", "wrong-visual", "wrong-text"])
            #expect(byID["visual-only"]?.visualSimilarity == 1)
            #expect(byID["visual-only"]?.recognizedText == nil)
            #expect(byID["text-only"]?.visualSimilarity == nil)
            #expect(byID["text-only"]?.recognizedText == "рецепт")
            #expect(byID["wrong-visual"]?.visualSimilarity == nil)
            #expect(byID["wrong-visual"]?.recognizedText == "рецепт")
            #expect(byID["wrong-text"]?.visualSimilarity == 1)
            #expect(byID["wrong-text"]?.recognizedText == nil)
        }
    }

    @Test
    func originalRussianTextDrivesOCRInsteadOfItsEnglishTranslation() async throws {
        try await withStore { store, _ in
            try await save(photo("russian"), text: "Рецепт блинов", in: store)
            try await save(photo("english"), text: "pancake recipe", in: store)
            let matches = try await store.search(query("рецепт", english: "pancake recipe"),
                                                  ocrVersion: versions.ocr)
            #expect(matches.map(\.photo.id) == ["russian"])
            #expect(matches.first?.recognizedText == "Рецепт блинов")
            #expect(matches.first?.visualSimilarity == nil)
        }
    }

    @Test
    func globalVisualRankingIncludesLaterPagesAndBreaksCrossPageTiesByID() async throws {
        try await withStore { store, _ in
            var expected: [(id: String, similarity: Float)] = []
            for position in 0..<257 {
                let id = String(format: "asset-%04d", position)
                // The best tied vectors straddle the page boundary and include its last row.
                let vector: CLIPEmbedding
                if [199, 200, 256].contains(position) {
                    vector = try embedding()
                } else {
                    vector = try embedding(Float(position % 37) - 18, 50)
                }
                try await save(photo(id), vector: vector, in: store)
                expected.append((id, vector.values[0]))
            }
            expected.sort {
                $0.similarity > $1.similarity || ($0.similarity == $1.similarity && $0.id < $1.id)
            }
            let prepared = try query("no matching text")
            let matches = try await store.search(prepared, ocrVersion: versions.ocr, limit: 100)

            #expect(matches.count == 100)
            #expect(matches.map(\.photo.id) == expected.prefix(100).map(\.id))
            #expect(matches.prefix(3).map(\.photo.id) == ["asset-0199", "asset-0200", "asset-0256"])
            #expect(matches.allSatisfy { $0.recognizedText == nil })
            #expect(matches.last?.score == 1.0 / 160.0)
            #expect(try await store.search(prepared, ocrVersion: versions.ocr, limit: 1) == [matches[0]])
            #expect(try await store.search(prepared, ocrVersion: versions.ocr).count == 50)
        }
    }

    @Test
    func ftsOperatorsAreLiteralTermsAndPunctuationDoesNotDisableVisualSearch() async throws {
        try await withStore { store, _ in
            try await save(photo("literal"), text: "кот OR собака", in: store)
            try await save(photo("cat"), text: "кот", in: store)
            try await save(photo("dog"), text: "собака", in: store)
            try await save(photo("both-words"), text: "кот собака", in: store)
            let literal = try await store.search(query("\"кот\" OR (собака*)"), ocrVersion: versions.ocr)
            #expect(literal.map(\.photo.id) == ["literal"])

            try await save(photo("visual"), vector: embedding(), in: store)
            let punctuation = try await store.search(query(" !!!... "), ocrVersion: versions.ocr)
            #expect(punctuation.map(\.photo.id) == ["visual"])
            #expect(punctuation.first?.recognizedText == nil)
            #expect(punctuation.first?.visualSimilarity == 1)
        }
    }

    @Test
    func emptyIndexAndResultLimitsHaveDefinedBehavior() async throws {
        try await withStore { store, _ in
            let prepared = try query("a beach")
            #expect(try await store.search(prepared, ocrVersion: versions.ocr).isEmpty)
            for limit in [Int.min, -1, 0, 101, Int.max] {
                await #expect(throws: PhotoSearchError.invalidLimit) {
                    try await store.search(prepared, ocrVersion: versions.ocr, limit: limit)
                }
            }
            await #expect(throws: QueryInputError.empty) {
                try await store.search(query(" \n\t "), ocrVersion: versions.ocr)
            }
            await #expect(throws: QueryInputError.tooLong) {
                try await store.search(query(String(repeating: "word ", count: 33)), ocrVersion: versions.ocr)
            }
        }
    }

    @Test
    func cancelledSearchDoesNotReturnPersistedMatchesOrChangeCompletedStages() async throws {
        try await withStore { store, _ in
            try await save(photo("asset"), vector: embedding(), text: "рецепт", in: store)
            let prepared = try query("рецепт")
            let ocrVersion = versions.ocr
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await store.search(prepared, ocrVersion: ocrVersion)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            let resumed = try await store.search(prepared, ocrVersion: versions.ocr)
            #expect(resumed.map(\.photo.id) == ["asset"])
            #expect(try await store.summary().completeCount == 1)
        }
    }

    private func photo(_ id: String) -> LibraryPhoto {
        LibraryPhoto(id: id, creationDate: nil, modificationDate: nil, pixelWidth: 640, pixelHeight: 480)
    }

    private func embedding(_ x: Float = 1, _ y: Float = 0,
                           modelID: String = "search-clip-v1") throws -> CLIPEmbedding {
        try CLIPEmbedding(rawValues: [x, y] + Array(repeating: 0, count: 510), modelID: modelID)
    }

    private func query(_ original: String, english: String = "recipe") throws -> PreparedQuery {
        PreparedQuery(originalText: original, englishText: english, sourceLanguage: .russian,
                      embedding: try embedding())
    }

    private func save(_ photo: LibraryPhoto, versions suppliedVersions: PhotoIndexVersions? = nil,
                      vector: CLIPEmbedding? = nil, text: String? = nil,
                      in store: PhotoIndexStore) async throws {
        _ = try await store.upsert(photo, versions: suppliedVersions ?? versions)
        if let vector {
            let work = try await store.beginWork(for: photo.id, stage: .embedding)
            try await store.saveEmbedding(vector, for: work)
        }
        if let text {
            let work = try await store.beginWork(for: photo.id, stage: .ocr)
            let result = PhotoOCRResult(lines: [PhotoOCRLine(text: text, confidence: 0.9,
                boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.1))],
                revision: 3, languages: ["ru-RU", "en-US"])
            try await store.saveOCR(result, for: work)
        }
    }

    private func withStore(_ body: (PhotoIndexStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoIndexSearchTests-\(UUID().uuidString)", isDirectory: true)
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
}
