import Foundation
import ImageIO
import Testing
import UIKit
@testable import PromptImage

/// Exercises the production CLIP/Vision processor and scheduler with synthetic
/// PNGs and a real temporary database. No PhotoKit requests or private images.
@Suite(.serialized)
@MainActor
struct PhotoIndexProcessorTests {
    @Test
    func realModelsPersistSearchableResultsAndReloadAfterPausing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoIndexProcessorTests-\(UUID().uuidString)", isDirectory: true)
        let database = try PhotoIndexStore(directoryURL: directory)
        let processor = PhotoIndexProcessor()
        let source = ProcessorImageSource(image: textImage())
        let indexing = PhotoIndexingStore(provider: source, processor: processor,
            openStore: { database }, isCurrentAndAccessible: { _ in true })
        let search = PhotoSearchPipeline(index: indexing)

        do {
            let versions = try await processor.versions()
            let expectedModelID = try CLIPModelResources().manifest.modelID
            #expect(versions.embedding == expectedModelID)
            #expect(versions.ocr == PhotoIndexPipeline.currentOCRVersion)
            let first = photo("first")
            indexing.setActive(true)
            indexing.updatePhotos([first])
            try await eventually { !indexing.isBusy }
            try #require(indexing.phase == .ready)
            #expect(source.requests.isEmpty)

            indexing.start()
            try await eventually { !indexing.isBusy }
            try #require(indexing.phase == .finished)

            #expect(indexing.summary.completeCount == 1)
            #expect(indexing.summary.failedCount == 0)
            #expect(source.requests.map(\.assetID) == [first.id])
            let initialVectors = try await database.embeddings(modelID: versions.embedding)
            let firstVector = try #require(initialVectors.first?.embedding)
            #expect(initialVectors.map(\.id) == [first.id])
            expectNormalized(firstVector, modelID: versions.embedding)
            let recognized = try #require(try await database.ocr(for: first.id, version: versions.ocr))
            #expect(recognized.text.localizedCaseInsensitiveContains("яблочного пирога"))
            #expect(recognized.text.localizedCaseInsensitiveContains("cinnamon"))
            #expect(try await database.searchOCR("яблочного cinnamon", version: versions.ocr)
                .map(\.assetID) == [first.id])

            // Exercise real bundled Russian translation, CLIP text encoding, and
            // fused retrieval against the real CLIP/Vision results saved above.
            for (query, language) in [("яблочного пирога", QueryLanguageChoice.russian),
                                      ("cinnamon", QueryLanguageChoice.english)] {
                let matches = try await search.search(query, language: language)
                #expect(matches.map(\.photo.id) == [first.id])
                let match = try #require(matches.first)
                #expect(match.visualSimilarity != nil)
                #expect(match.recognizedText == recognized.text)
                #expect(abs(match.score - 2.0 / 61.0) < 1e-12)
            }
            await search.unload()
            #expect(source.requests.count == 1)

            // The first completed run unloads the image model. Pause a later run
            // while it awaits its source, then resume using the same real processor.
            // This requires the image model to load again without redoing the first photo.
            let second = photo("second")
            source.deferredAssetIDs = [second.id]
            indexing.pause()
            indexing.updatePhotos([first, second])
            try await eventually { !indexing.isBusy }
            try #require(indexing.phase == .ready)
            indexing.start()
            try await eventually { source.requests.count == 2 }
            let interruptedRequest = source.requests[1]
            indexing.pause()
            try await eventually { !indexing.isBusy }
            #expect(indexing.phase == .paused)
            #expect(source.cancelled == [interruptedRequest.id])
            #expect(indexing.summary.completeCount == 1)
            #expect(try await database.record(for: second.id)?.embedding.status == .pending)
            #expect(try await database.record(for: second.id)?.ocr.status == .pending)

            source.deferredAssetIDs = []
            indexing.start()
            try await eventually { !indexing.isBusy }
            try #require(indexing.phase == .finished)

            #expect(indexing.summary.completeCount == 2)
            #expect(indexing.summary.failedCount == 0)
            #expect(source.requests.map(\.assetID) == [first.id, second.id, second.id])
            let vectors = try await database.embeddings(modelID: versions.embedding)
            #expect(vectors.map(\.id) == [first.id, second.id])
            let secondVector = try #require(vectors.last?.embedding)
            expectNormalized(secondVector, modelID: versions.embedding)
            #expect(try firstVector.cosineSimilarity(to: secondVector) > 0.999)
            #expect(try await database.searchOCR("яблочного cinnamon", version: versions.ocr)
                .map(\.assetID) == [first.id, second.id])

            indexing.pause()
            await indexing.waitForIdle()
            try await database.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            indexing.pause()
            await indexing.waitForIdle()
            await search.unload()
            await processor.unload()
            try? await database.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func expectNormalized(_ embedding: CLIPEmbedding, modelID: String) {
        #expect(embedding.modelID == modelID)
        #expect(embedding.values.count == 512)
        let allFinite = embedding.values.allSatisfy { $0.isFinite }
        #expect(allFinite)
        let norm = sqrt(embedding.values.reduce(0.0) { $0 + Double($1) * Double($1) })
        #expect(abs(norm - 1) < 0.000_01)
    }

    private func photo(_ id: String) -> LibraryPhoto {
        LibraryPhoto(id: id, creationDate: nil, modificationDate: nil, pixelWidth: 1_200, pixelHeight: 480)
    }

    private func textImage() -> PhotoOCRSource {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 480), format: format)
        let data = renderer.pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 480))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black,
            ]
            ("Рецепт яблочного пирога" as NSString)
                .draw(at: CGPoint(x: 60, y: 60), withAttributes: attributes)
            ("Add cinnamon and sugar" as NSString)
                .draw(at: CGPoint(x: 60, y: 190), withAttributes: attributes)
        }
        return PhotoOCRSource(data: data, orientation: .up)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(120))
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProcessorTestError.timedOut
    }
}

private enum ProcessorTestError: Error { case timedOut }

@MainActor
private final class ProcessorImageSource: PhotoOCRSourceProviding {
    struct Request {
        let id: UUID
        let assetID: String
    }

    private let image: PhotoOCRSource
    var deferredAssetIDs: Set<String> = []
    private(set) var requests: [Request] = []
    private(set) var cancelled: [UUID] = []

    init(image: PhotoOCRSource) { self.image = image }

    func requestSource(for photo: LibraryPhoto,
                       completion: @escaping @MainActor (PhotoOCRSourceResult) -> Void) -> UUID {
        let id = UUID()
        requests.append(Request(id: id, assetID: photo.id))
        if !deferredAssetIDs.contains(photo.id) { completion(.source(image)) }
        return id
    }

    func cancel(_ requestID: UUID) { cancelled.append(requestID) }
}
