import Foundation
import Testing
@testable import PromptImage

struct CLIPEmbeddingTests {
    @Test
    func normalizesVectorsAndComputesCosine() throws {
        let raw: [Float] = [3, 4] + Array(repeating: 0, count: 510)
        let positive = try CLIPEmbedding(rawValues: raw, modelID: "test")
        let negative = try CLIPEmbedding(rawValues: raw.map { -$0 }, modelID: "test")
        #expect(abs(positive.values[0] - 0.6) < 1e-6)
        #expect(abs(positive.values[1] - 0.8) < 1e-6)
        #expect(abs(try positive.cosineSimilarity(to: positive) - 1) < 1e-6)
        #expect(abs(try positive.cosineSimilarity(to: negative) + 1) < 1e-6)
    }

    @Test
    func rejectsMalformedEmbeddingsAndDifferentModelSpaces() throws {
        #expect(throws: CLIPEmbeddingError.invalidDimension) {
            try CLIPEmbedding(rawValues: [1, 2], modelID: "test")
        }
        for value in [Float(0), .nan, .infinity, -.infinity] {
            #expect(throws: CLIPEmbeddingError.invalidValues) {
                try CLIPEmbedding(rawValues: Array(repeating: value, count: 512), modelID: "test")
            }
        }
        let a = try CLIPEmbedding(rawValues: Array(repeating: 1, count: 512), modelID: "a")
        let b = try CLIPEmbedding(rawValues: Array(repeating: 1, count: 512), modelID: "b")
        #expect(throws: CLIPEmbeddingError.incompatibleModels) { try a.cosineSimilarity(to: b) }
    }

    @Test(arguments: [Float.greatestFiniteMagnitude, Float.leastNonzeroMagnitude])
    func normalizationAvoidsOverflowAndUnderflow(value: Float) throws {
        let vector = try CLIPEmbedding(rawValues: Array(repeating: value, count: 512), modelID: "test")
        #expect(vector.values.allSatisfy { $0.isFinite })
        #expect(abs(try vector.cosineSimilarity(to: vector) - 1) < 1e-6)
    }
}
