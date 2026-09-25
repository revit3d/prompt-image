import Foundation

nonisolated enum SemanticImageIndexError: Error, Equatable {
    case invalidID
    case duplicateID(String)
    case tooManyImages
    case invalidTopK
}

/// The identifier belongs to the caller's corpus; no PhotoKit access or persistence occurs here.
nonisolated struct SemanticIndexedImage: Sendable {
    let id: String
    let embedding: CLIPEmbedding
}

nonisolated struct SemanticImageMatch: Sendable, Equatable {
    let id: String
    /// Cosine similarity in [-1, 1], not a probability or confidence percentage.
    let score: Float
}

/// An immutable, bounded index for evaluating image/text embeddings in the same model space.
nonisolated struct SemanticImageIndex: Sendable {
    static let maximumImageCount = 10_000
    static let maximumTopK = 100

    let modelID: String
    var imageCount: Int { images.count }
    private let images: [SemanticIndexedImage]

    init(modelID: String, images: [SemanticIndexedImage]) throws {
        try Task.checkCancellation()
        guard images.count <= Self.maximumImageCount else {
            throw SemanticImageIndexError.tooManyImages
        }
        var identifiers = Set<String>()
        identifiers.reserveCapacity(images.count)
        for image in images {
            try Task.checkCancellation()
            guard !image.id.isEmpty else { throw SemanticImageIndexError.invalidID }
            guard identifiers.insert(image.id).inserted else {
                throw SemanticImageIndexError.duplicateID(image.id)
            }
            guard image.embedding.modelID == modelID else {
                throw CLIPEmbeddingError.incompatibleModels
            }
        }
        self.modelID = modelID
        self.images = images
    }

    /// Scores every image, retaining at most topK results. Equal scores use ascending IDs.
    /// Call from a worker actor/task for a large corpus; cancellation is checked per image.
    func search(query: CLIPEmbedding, topK: Int = 10) throws -> [SemanticImageMatch] {
        try Task.checkCancellation()
        guard (1...Self.maximumTopK).contains(topK) else {
            throw SemanticImageIndexError.invalidTopK
        }
        guard query.modelID == modelID else { throw CLIPEmbeddingError.incompatibleModels }

        var matches: [SemanticImageMatch] = []
        matches.reserveCapacity(min(topK, images.count))
        for image in images {
            try Task.checkCancellation()
            let match = SemanticImageMatch(id: image.id,
                                           score: try image.embedding.cosineSimilarity(to: query))
            if matches.count == topK, let last = matches.last, !Self.precedes(match, last) {
                continue
            }

            // A bounded sorted array avoids allocating or sorting one score per corpus image.
            var lower = 0
            var upper = matches.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if Self.precedes(matches[middle], match) {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            matches.insert(match, at: lower)
            if matches.count > topK { matches.removeLast() }
        }
        try Task.checkCancellation()
        return matches
    }

    private static func precedes(_ lhs: SemanticImageMatch, _ rhs: SemanticImageMatch) -> Bool {
        lhs.score > rhs.score || (lhs.score == rhs.score && lhs.id < rhs.id)
    }
}
