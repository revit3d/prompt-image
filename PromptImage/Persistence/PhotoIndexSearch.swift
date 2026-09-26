import Foundation

extension PhotoIndexStore {
    /// Preserves SQLite's BM25 ordering, including its deterministic ID tie-break.
    /// Neither visual vectors nor model metadata are loaded by text-only search.
    func searchText(_ text: String, ocrVersion: String, limit: Int = 50) throws -> [PhotoSearchMatch] {
        try Task.checkCancellation()
        try PhotoSearchPipeline.validate(text, limit: limit)
        let ranked = try searchOCR(text, version: ocrVersion, limit: limit)
        let matches = try ReciprocalRankFusion.combine(visual: [], text: ranked, limit: limit)
        return try matches.map { match in
            try Task.checkCancellation()
            guard let record = try record(for: match.assetID) else { throw PhotoIndexError.invalidStoredData }
            return PhotoSearchMatch(photo: record.photo, score: match.score,
                visualSimilarity: nil, recognizedText: match.recognizedText)
        }
    }

    /// One uninterrupted actor turn reads both channels and their source metadata.
    /// Only the index owner may publish these results after validating current access.
    /// Scans all compatible vectors in bounded pages, including libraries above 10,000.
    func search(_ query: PreparedQuery, ocrVersion: String, limit: Int = 50) throws -> [PhotoSearchMatch] {
        try Task.checkCancellation()
        try PhotoSearchPipeline.validate(query.originalText, limit: limit)
        let candidateLimit = ReciprocalRankFusion.candidateLimit
        let pageSize = 200
        var afterID: String?
        var visual: [SemanticImageMatch] = []
        while true {
            try Task.checkCancellation()
            let page = try embeddings(modelID: query.embedding.modelID, afterID: afterID, limit: pageSize)
            guard !page.isEmpty else { break }
            let index = try SemanticImageIndex(modelID: query.embedding.modelID, images: page)
            let ranked = try index.search(query: query.embedding, topK: candidateLimit)
            visual = Array((visual + ranked).sorted {
                $0.score > $1.score || ($0.score == $1.score && $0.id < $1.id)
            }.prefix(candidateLimit))
            afterID = page.last?.id
            if page.count < pageSize { break }
        }
        try Task.checkCancellation()
        let text = try searchOCR(query.originalText, version: ocrVersion, limit: candidateLimit)
        let fused = try ReciprocalRankFusion.combine(visual: visual, text: text, limit: limit)
        return try fused.map { match in
            try Task.checkCancellation()
            guard let record = try record(for: match.assetID) else { throw PhotoIndexError.invalidStoredData }
            return PhotoSearchMatch(photo: record.photo, score: match.score,
                visualSimilarity: match.visualSimilarity, recognizedText: match.recognizedText)
        }
    }
}
