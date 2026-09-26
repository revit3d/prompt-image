import Foundation
import Testing
@testable import PromptImage

struct ReciprocalRankFusionTests {
    @Test
    func agreementAcrossChannelsBoostsAnAssetWithoutDuplicatingIt() throws {
        let matches = try ReciprocalRankFusion.combine(visual: [
            .init(id: "visual-first", score: 0.95),
            .init(id: "both", score: 0.7)
        ], text: [
            .init(assetID: "text-first", text: "рецепт", rank: -10),
            .init(assetID: "both", text: "рецепт блинов", rank: -1)
        ], limit: 10)

        #expect(matches.map(\.assetID) == ["both", "text-first", "visual-first"])
        #expect(abs(matches[0].score - 2.0 / 62.0) < 1e-12)
        #expect(matches[0].visualSimilarity == 0.7)
        #expect(matches[0].recognizedText == "рецепт блинов")
        #expect(matches[1].visualSimilarity == nil)
        #expect(matches[2].recognizedText == nil)
    }

    @Test
    func rawScoreScaleDoesNotAffectFusion() throws {
        func rank(visualScores: [Float], textRanks: [Double]) throws -> [FusedPhotoMatch] {
            try ReciprocalRankFusion.combine(visual: [
                .init(id: "a", score: visualScores[0]),
                .init(id: "b", score: visualScores[1])
            ], text: [
                .init(assetID: "b", text: "first", rank: textRanks[0]),
                .init(assetID: "c", text: "second", rank: textRanks[1])
            ], limit: 10)
        }
        let first = try rank(visualScores: [1, 0.99], textRanks: [-1_000, -10])
        let rescaled = try rank(visualScores: [-0.5, -0.9], textRanks: [-0.0001, -0.00001])

        #expect(first.map(\.assetID) == ["b", "a", "c"])
        #expect(first.map(\.assetID) == rescaled.map(\.assetID))
        #expect(first.map(\.score) == rescaled.map(\.score))
    }

    @Test
    func eitherChannelWorksAloneAndEmptyCandidatesReturnNothing() throws {
        let visual = try ReciprocalRankFusion.combine(visual: [
            .init(id: "z", score: 0), .init(id: "a", score: -1)
        ], text: [], limit: 100)
        #expect(visual.map(\.assetID) == ["z", "a"])
        #expect(visual[0].score == 1.0 / 61.0)
        #expect(visual[1].score == 1.0 / 62.0)
        #expect(visual[1].visualSimilarity == -1)

        let text = try ReciprocalRankFusion.combine(visual: [], text: [
            .init(assetID: "z", text: "первый", rank: -2),
            .init(assetID: "a", text: "второй", rank: -1)
        ], limit: 100)
        #expect(text.map(\.assetID) == ["z", "a"])
        #expect(text.map(\.score) == visual.map(\.score))
        #expect(text.allSatisfy { $0.visualSimilarity == nil })
        #expect(try ReciprocalRankFusion.combine(visual: [], text: [], limit: 1).isEmpty)
    }

    @Test
    func duplicateCandidatesContributeOnlyTheirFirstSourceRankAndMetadata() throws {
        let matches = try ReciprocalRankFusion.combine(visual: [
            .init(id: "both", score: 0.9),
            .init(id: "both", score: 0.8),
            .init(id: "visual", score: 0.7)
        ], text: [
            .init(assetID: "text", text: "first text", rank: -10),
            .init(assetID: "both", text: "first shared text", rank: -5),
            .init(assetID: "both", text: "duplicate shared text", rank: -4),
            .init(assetID: "text", text: "duplicate text", rank: -3)
        ], limit: 100)

        #expect(matches.map(\.assetID) == ["both", "text", "visual"])
        #expect(matches[0].score == 1.0 / 61.0 + 1.0 / 62.0)
        #expect(matches[0].visualSimilarity == 0.9)
        #expect(matches[0].recognizedText == "first shared text")
        #expect(matches[1].score == 1.0 / 61.0)
        #expect(matches[1].recognizedText == "first text")
        #expect(matches[2].score == 1.0 / 63.0)
    }

    @Test
    func equalFusionScoresUseAscendingIdentifiersBeforeApplyingLimit() throws {
        let visual: [SemanticImageMatch] = [.init(id: "z", score: 1), .init(id: "a", score: 0)]
        let text: [PhotoIndexTextMatch] = [
            .init(assetID: "a", text: "first", rank: -2),
            .init(assetID: "z", text: "second", rank: -1)
        ]
        let all = try ReciprocalRankFusion.combine(visual: visual, text: text, limit: 100)
        #expect(all.map(\.assetID) == ["a", "z"])
        #expect(all[0].score == all[1].score)
        #expect(try ReciprocalRankFusion.combine(visual: visual, text: text, limit: 1) == [all[0]])
    }

    @Test(arguments: [Int.min, -1, 0, 101, Int.max])
    func rejectsInvalidResultLimits(limit: Int) throws {
        #expect(throws: PhotoSearchError.invalidLimit) {
            try ReciprocalRankFusion.combine(visual: [], text: [], limit: limit)
        }
    }

    @Test
    func cancellationRejectsEvenEmptyCandidates() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ReciprocalRankFusion.combine(visual: [], text: [], limit: 1)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
