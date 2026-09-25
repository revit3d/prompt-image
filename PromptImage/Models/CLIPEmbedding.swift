import Foundation

nonisolated enum CLIPEmbeddingError: Error, Equatable {
    case invalidDimension
    case invalidValues
    case incompatibleModels
    case invalidModelOutput
}

/// A finite, unit-length vector in one version of the shared image/text space.
nonisolated struct CLIPEmbedding: Sendable, Equatable {
    let modelID: String
    let values: [Float]

    init(rawValues: [Float], modelID: String) throws {
        guard rawValues.count == 512 else { throw CLIPEmbeddingError.invalidDimension }
        guard rawValues.allSatisfy(\.isFinite) else { throw CLIPEmbeddingError.invalidValues }
        // Accumulate in Double to avoid overflow/underflow for otherwise finite Floats.
        let norm = sqrt(rawValues.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0 else { throw CLIPEmbeddingError.invalidValues }
        self.modelID = modelID
        values = rawValues.map { Float(Double($0) / norm) }
    }

    func cosineSimilarity(to other: CLIPEmbedding) throws -> Float {
        guard modelID == other.modelID else { throw CLIPEmbeddingError.incompatibleModels }
        let dot = zip(values, other.values).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        return Float(min(1, max(-1, dot)))
    }
}
