import CoreGraphics
import Foundation
import Testing
@testable import PromptImage

struct PhotoOCRLineMergerTests {
    @Test
    func aLineRecognizedOnlyBesideATileEdgeSurvives() {
        let line = detection("Рецепт блинов", tile: 0, interior: false)

        #expect(PhotoOCRLineMerger.merge([line]) == [line.line])
    }

    @Test
    func duplicateSeamDetectionsWithDifferentCentersMerge() {
        let first = detection("Рецепт блинов", tile: 0, confidence: 0.8,
                              box: CGRect(x: 0.1, y: 0.45, width: 0.8, height: 0.02))
        let second = detection("Рецепт блинов", tile: 1, confidence: 0.9,
                               box: CGRect(x: 0.101, y: 0.453, width: 0.795, height: 0.02))

        #expect(PhotoOCRLineMerger.merge([first, second]) == [second.line])
        #expect(PhotoOCRLineMerger.merge([second, first]) == [second.line])
    }

    @Test
    func completeTextWinsOverAConfidentClippedFragment() {
        let fragment = detection("milk and", tile: 0, confidence: 0.99, interior: false,
                                 box: CGRect(x: 0.1, y: 0.4, width: 0.25, height: 0.05))
        let complete = detection("milk and eggs", tile: 1, confidence: 0.65,
                                 box: CGRect(x: 0.1, y: 0.4, width: 0.7, height: 0.05))

        #expect(PhotoOCRLineMerger.merge([fragment, complete]) == [complete.line])
        #expect(PhotoOCRLineMerger.merge([complete, fragment]) == [complete.line])
    }

    @Test
    func equalTextAtDistantPositionsIsNotDeduplicated() {
        let top = detection("Повтор строки", tile: 0,
                            box: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.04))
        let bottom = detection("Повтор строки", tile: 3,
                               box: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.04))

        #expect(PhotoOCRLineMerger.merge([bottom, top]) == [top.line, bottom.line])
    }

    @Test
    func detectionsFromTheSameTileRemainIndependent() {
        let first = detection("same line", tile: 0, confidence: 0.8)
        let second = detection("same line", tile: 0, confidence: 0.9)

        #expect(PhotoOCRLineMerger.merge([first, second]).count == 2)
    }

    @Test
    func strongSameLineGeometryResolvesDifferentRecognizedSpelling() {
        let misspelled = detection("Молоко 2О0 мл", tile: 0, confidence: 0.8,
                                  box: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.05))
        let correct = detection("Молоко 200 мл", tile: 1, confidence: 0.95,
                               box: CGRect(x: 0.105, y: 0.402, width: 0.79, height: 0.05))

        #expect(PhotoOCRLineMerger.merge([misspelled, correct]) == [correct.line])
    }

    @Test
    func anInteriorDetectionWinsOverAnEdgeDetection() {
        let edge = detection("Pancake recipe", tile: 0, confidence: 0.98, interior: false)
        let interior = detection("Pancake recipe", tile: 1, confidence: 0.9)

        #expect(PhotoOCRLineMerger.merge([edge, interior]) == [interior.line])
    }

    @Test
    func nearbyDistinctRowsSurviveEvenWithOverlappingBoxes() {
        let first = detection("100 ml milk", tile: 0,
                              box: CGRect(x: 0.1, y: 0.42, width: 0.8, height: 0.05))
        let second = detection("100 ml milk", tile: 1,
                               box: CGRect(x: 0.1, y: 0.38, width: 0.8, height: 0.05))

        #expect(PhotoOCRLineMerger.merge([first, second]) == [first.line, second.line])
    }

    @Test
    func aCompleteObservationReplacesTwoFragmentsFromItsNeighbor() {
        let left = detection("milk and", tile: 0, interior: false,
                             box: CGRect(x: 0.1, y: 0.4, width: 0.25, height: 0.05))
        let right = detection("eggs", tile: 0, interior: false,
                              box: CGRect(x: 0.6, y: 0.4, width: 0.2, height: 0.05))
        let full = detection("milk and eggs", tile: 1,
                             box: CGRect(x: 0.1, y: 0.4, width: 0.7, height: 0.05))

        #expect(PhotoOCRLineMerger.merge([left, right, full]) == [full.line])
        #expect(PhotoOCRLineMerger.merge([full, left, right]) == [full.line])
    }

    @Test
    func internalEdgePreferenceDoesNotPenalizeTheOuterImageBoundary() {
        let imageSize = CGSize(width: 1_000, height: 4_000)
        let lower = PhotoOCRImage.Tile(region: CGRect(x: 0, y: 0, width: 1_000, height: 2_048))
        let upper = PhotoOCRImage.Tile(region: CGRect(x: 0, y: 1_792, width: 1_000, height: 2_048))

        #expect(lower.isInterior(CGRect(x: 0, y: 0, width: 0.5, height: 0.05), imageSize: imageSize))
        #expect(!upper.isInterior(CGRect(x: 0.1, y: 0, width: 0.5, height: 0.05), imageSize: imageSize))
        #expect(!lower.isInterior(CGRect(x: 0.1, y: 0.995, width: 0.5, height: 0.005), imageSize: imageSize))
    }

    private func detection(
        _ text: String,
        tile: Int,
        confidence: Float = 0.9,
        interior: Bool = true,
        box: CGRect = CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.05)
    ) -> PhotoOCRLineMerger.Detection {
        PhotoOCRLineMerger.Detection(
            line: PhotoOCRLine(text: text, confidence: confidence, boundingBox: box),
            tileIndex: tile,
            isInterior: interior
        )
    }
}
