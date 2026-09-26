import Testing
@testable import PromptImage

struct PhotoSearchCoverageTests {
    @Test(arguments: [PhotoSearchMode.combined, .textOnly])
    func anEmptyIndexNeverClaimsTheLibraryIsPrepared(mode: PhotoSearchMode) {
        let coverage = PhotoSearchCoverage(summary: .empty, mode: mode)

        #expect(!coverage.isComplete)
    }

    @Test
    func textSearchCanBeCompleteBeforeVisualProcessingFinishes() {
        let summary = PhotoIndexSummary(totalCount: 10, completeCount: 3,
            embeddingCount: 3, ocrCount: 10, pendingCount: 7,
            downloadRequiredCount: 2, failedCount: 1)

        #expect(PhotoSearchCoverage(summary: summary, mode: .textOnly).isComplete)
        #expect(!PhotoSearchCoverage(summary: summary, mode: .combined).isComplete)
    }

    @Test
    func completeVisualEmbeddingsDoNotImplyCompleteTextSearch() {
        let summary = PhotoIndexSummary(totalCount: 10, completeCount: 4,
            embeddingCount: 10, ocrCount: 4, pendingCount: 6,
            downloadRequiredCount: 3, failedCount: 1)

        #expect(!PhotoSearchCoverage(summary: summary, mode: .textOnly).isComplete)
        #expect(!PhotoSearchCoverage(summary: summary, mode: .combined).isComplete)
    }

    @Test(arguments: [PhotoSearchMode.combined, .textOnly])
    func everyPhotoPreparedForBothChannelsMeansCompleteCoverage(mode: PhotoSearchMode) {
        let summary = PhotoIndexSummary(totalCount: 10, completeCount: 10,
            embeddingCount: 10, ocrCount: 10, pendingCount: 0,
            downloadRequiredCount: 0, failedCount: 0)

        #expect(PhotoSearchCoverage(summary: summary, mode: mode).isComplete)
    }

    @Test
    func overlappingStagesAreReportedSeparatelyWithoutAddingPhotoCounts() {
        // Two photos have both stages, four have only embeddings, four only OCR.
        let summary = PhotoIndexSummary(totalCount: 10, completeCount: 2,
            embeddingCount: 6, ocrCount: 6, pendingCount: 8,
            downloadRequiredCount: 3, failedCount: 2)
        let combined = PhotoSearchCoverage(summary: summary, mode: .combined)
        let textOnly = PhotoSearchCoverage(summary: summary, mode: .textOnly)

        #expect(!combined.isComplete)
        #expect(combined.detail == "По описанию: 6 из 10 фото. По тексту: 6 из 10 фото.")
        #expect(textOnly.detail == "Текст подготовлен: 6 из 10 фото.")
        #expect(combined.summary == summary)
    }
}
