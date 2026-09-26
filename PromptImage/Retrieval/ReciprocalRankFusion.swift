import Foundation

nonisolated struct FusedPhotoMatch: Sendable, Equatable {
    let assetID: String
    /// A sum of reciprocal ranks, not a probability or a cosine similarity.
    let score: Double
    let visualSimilarity: Float?
    let recognizedText: String?
}

/// Combines already ordered candidates without comparing unlike cosine/BM25 scores.
nonisolated enum ReciprocalRankFusion {
    static let candidateLimit = 100
    private static let rankConstant = 60.0

    static func combine(
        visual: [SemanticImageMatch], text: [PhotoIndexTextMatch], limit: Int
    ) throws -> [FusedPhotoMatch] {
        try Task.checkCancellation()
        guard (1...candidateLimit).contains(limit) else { throw PhotoSearchError.invalidLimit }

        var matches: [String: FusedPhotoMatch] = [:]
        for (offset, match) in visual.enumerated() {
            try Task.checkCancellation()
            // A repeated candidate contributes only its first, best source rank.
            guard matches[match.id] == nil else { continue }
            matches[match.id] = FusedPhotoMatch(assetID: match.id,
                score: reciprocalRank(offset), visualSimilarity: match.score, recognizedText: nil)
        }

        var seenTextIDs = Set<String>()
        for (offset, match) in text.enumerated() {
            try Task.checkCancellation()
            guard seenTextIDs.insert(match.assetID).inserted else { continue }
            let visualMatch = matches[match.assetID]
            matches[match.assetID] = FusedPhotoMatch(assetID: match.assetID,
                score: (visualMatch?.score ?? 0) + reciprocalRank(offset),
                visualSimilarity: visualMatch?.visualSimilarity, recognizedText: match.text)
        }

        let ordered = matches.values.sorted {
            $0.score > $1.score || ($0.score == $1.score && $0.assetID < $1.assetID)
        }
        try Task.checkCancellation()
        return Array(ordered.prefix(limit))
    }

    private static func reciprocalRank(_ offset: Int) -> Double {
        1 / (rankConstant + Double(offset) + 1)
    }
}
