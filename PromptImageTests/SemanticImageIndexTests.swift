import Foundation
import Testing
@testable import PromptImage

struct SemanticImageIndexTests {
    private func embedding(_ x: Float, _ y: Float = 0, modelID: String = "test") throws -> CLIPEmbedding {
        try CLIPEmbedding(rawValues: [x, y] + Array(repeating: 0, count: 510), modelID: modelID)
    }

    @Test
    func ranksByCosineAndKeepsNegativeScores() throws {
        let index = try SemanticImageIndex(modelID: "test", images: [
            SemanticIndexedImage(id: "opposite", embedding: embedding(-1)),
            SemanticIndexedImage(id: "diagonal", embedding: embedding(1, 1)),
            SemanticIndexedImage(id: "orthogonal", embedding: embedding(0, 1)),
            SemanticIndexedImage(id: "same", embedding: embedding(2))
        ])
        let matches = try index.search(query: embedding(1))
        #expect(matches.map(\.id) == ["same", "diagonal", "orthogonal", "opposite"])
        #expect(matches.first?.score == 1)
        #expect(abs(matches[1].score - 0.70710677) < 1e-6)
        #expect(matches[2].score == 0)
        #expect(matches.last?.score == -1)
        #expect(index.imageCount == 4)
        #expect(try index.search(query: embedding(1), topK: 2) == Array(matches.prefix(2)))
    }

    @Test
    func breaksScoreTiesByIDRegardlessOfInputOrder() throws {
        let vector = try embedding(1)
        let ids = ["z", "B", "a", "A", "10", "2"]
        for order in [ids, Array(ids.reversed()), Array(ids.dropFirst()) + [ids[0]]] {
            let index = try SemanticImageIndex(modelID: "test", images: order.map {
                SemanticIndexedImage(id: $0, embedding: vector)
            })
            #expect(try index.search(query: vector, topK: 3).map(\.id) == ["10", "2", "A"])
        }
    }

    @Test
    func boundedSelectionMatchesFullRankingAcrossCutoffs() throws {
        let query = try embedding(1)
        var images: [SemanticIndexedImage] = []
        for position in 0..<257 {
            let value = (position * 37) % 257
            let vector = try embedding(Float(value % 17) - 8, 8)
            images.append(SemanticIndexedImage(id: String(format: "%03d", value), embedding: vector))
        }
        var expected: [SemanticImageMatch] = []
        for image in images {
            let score: Float = try image.embedding.cosineSimilarity(to: query)
            expected.append(SemanticImageMatch(id: image.id, score: score))
        }
        expected.sort { (lhs: SemanticImageMatch, rhs: SemanticImageMatch) -> Bool in
            if lhs.score == rhs.score { return lhs.id < rhs.id }
            return lhs.score > rhs.score
        }
        let index = try SemanticImageIndex(modelID: "test", images: images)
        for cutoff in [1, 2, 7, 50, 99, 100] {
            let actual: [SemanticImageMatch] = try index.search(query: query, topK: cutoff)
            let prefix: [SemanticImageMatch] = Array(expected.prefix(cutoff))
            #expect(actual == prefix)
        }
    }

    @Test
    func rejectsDuplicateAndEmptyIdentifiers() throws {
        let vector = try embedding(1)
        #expect(throws: SemanticImageIndexError.invalidID) {
            try SemanticImageIndex(modelID: "test", images: [.init(id: "", embedding: vector)])
        }
        #expect(throws: SemanticImageIndexError.duplicateID("same")) {
            try SemanticImageIndex(modelID: "test", images: [
                .init(id: "same", embedding: vector), .init(id: "same", embedding: vector)
            ])
        }
    }

    @Test
    func rejectsDifferentModelSpacesForImagesAndQueries() throws {
        let wrongModel = try embedding(1, modelID: "different")
        #expect(throws: CLIPEmbeddingError.incompatibleModels) {
            try SemanticImageIndex(modelID: "test", images: [.init(id: "image", embedding: wrongModel)])
        }
        for images in [[], [SemanticIndexedImage(id: "image", embedding: try embedding(1))]] {
            let index = try SemanticImageIndex(modelID: "test", images: images)
            #expect(throws: CLIPEmbeddingError.incompatibleModels) { try index.search(query: wrongModel) }
        }
    }

    @Test
    func validatesLimitsAndAllowsEmptyCorpus() throws {
        let vector = try embedding(1)
        let empty = try SemanticImageIndex(modelID: "test", images: [])
        #expect(try empty.search(query: vector).isEmpty)
        for topK in [Int.min, -1, 0, SemanticImageIndex.maximumTopK + 1, Int.max] {
            #expect(throws: SemanticImageIndexError.invalidTopK) {
                try empty.search(query: vector, topK: topK)
            }
        }
        let images = (0..<SemanticImageIndex.maximumImageCount).map {
            SemanticIndexedImage(id: String(format: "%05d", $0), embedding: vector)
        }
        let full = try SemanticImageIndex(modelID: "test", images: images)
        let matches = try full.search(query: vector, topK: SemanticImageIndex.maximumTopK)
        #expect(matches.count == SemanticImageIndex.maximumTopK)
        #expect(matches.first?.id == "00000")
        #expect(matches.last?.id == "00099")
        #expect(throws: SemanticImageIndexError.tooManyImages) {
            try SemanticImageIndex(modelID: "test", images: images + [.init(id: "overflow", embedding: vector)])
        }
    }

    @Test
    func cancelledTasksDoNotConstructOrSearchAnIndex() async throws {
        let vector = try embedding(1)
        let index = try SemanticImageIndex(modelID: "test", images: [.init(id: "image", embedding: vector)])
        let cancelledConstruction = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SemanticImageIndex(modelID: "test", images: [])
        }
        await #expect(throws: CancellationError.self) { try await cancelledConstruction.value }
        let cancelledSearch = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try index.search(query: vector)
        }
        await #expect(throws: CancellationError.self) { try await cancelledSearch.value }
    }
}
