import Foundation

/// A snapshot of the permitted index when a search starts, not a count of results.
/// Stage counts overlap and must never be added to estimate unique photographs.
nonisolated struct PhotoSearchCoverage: Equatable, Sendable {
    let summary: PhotoIndexSummary
    let mode: PhotoSearchMode

    var isComplete: Bool {
        guard summary.totalCount > 0 else { return false }
        return mode == .textOnly
            ? summary.ocrCount == summary.totalCount
            : summary.completeCount == summary.totalCount
    }

    var title: String {
        isComplete ? "Все доступные фотографии подготовлены" : "Индекс готов частично"
    }

    var detail: String {
        if mode == .textOnly {
            "Текст подготовлен: \(summary.ocrCount) из \(summary.totalCount) фото."
        } else {
            "По описанию: \(summary.embeddingCount) из \(summary.totalCount) фото. По тексту: \(summary.ocrCount) из \(summary.totalCount) фото."
        }
    }
}

nonisolated struct PhotoSearchResultContext: Equatable, Sendable {
    let query: String
    let coverage: PhotoSearchCoverage
}
