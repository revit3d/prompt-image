import CoreGraphics
import Foundation
import Testing
@testable import PromptImage

struct PhotoIndexCodecTests {
    @Test
    func embeddingRoundTripUsesExactly512LittleEndianFloat32Values() throws {
        let embedding = try CLIPEmbedding(rawValues: [1] + Array(repeating: 0, count: 511), modelID: "clip-test")
        let data = try PhotoIndexCodec.encodeEmbedding(embedding)

        #expect(data.count == 2_048)
        #expect(Array(data.prefix(4)) == [0, 0, 128, 63])
        #expect(data.dropFirst(4).allSatisfy { $0 == 0 })
        #expect(try PhotoIndexCodec.decodeEmbedding(data, modelID: "clip-test") == embedding)

        let dense = try CLIPEmbedding(rawValues: (0..<512).map { Float($0 - 256) }, modelID: "clip-test")
        let decoded = try PhotoIndexCodec.decodeEmbedding(PhotoIndexCodec.encodeEmbedding(dense), modelID: "clip-test")
        #expect(zip(dense.values, decoded.values).allSatisfy { abs($0.0 - $0.1) < 0.000_001 })
    }

    @Test
    func decodingHandlesADataSliceWithoutAssumingAlignedStorage() throws {
        let embedding = try CLIPEmbedding(rawValues: [1] + Array(repeating: 0, count: 511), modelID: "test")
        let bytes = Data([255]) + (try PhotoIndexCodec.encodeEmbedding(embedding))
        #expect(try PhotoIndexCodec.decodeEmbedding(bytes.dropFirst(), modelID: "test") == embedding)
    }

    @Test
    func rejectsMalformedEmbeddingSizesAndNonUnitValues() throws {
        for size in [0, 1, 2_047, 2_049] {
            #expect(throws: PhotoIndexError.invalidStoredData) {
                try PhotoIndexCodec.decodeEmbedding(Data(repeating: 0, count: size), modelID: "test")
            }
        }
        for value in [Float(0), 2, .nan, .infinity, -.infinity] {
            #expect(throws: PhotoIndexError.invalidStoredData) {
                try PhotoIndexCodec.decodeEmbedding(vectorBytes(first: value), modelID: "test")
            }
        }
    }

    @Test
    func rejectsMissingModelIdentityOnBothReadAndWrite() throws {
        for modelID in ["", " \n", String(repeating: "a", count: 1_025)] {
            let embedding = try CLIPEmbedding(rawValues: [1] + Array(repeating: 0, count: 511), modelID: modelID)
            #expect(throws: PhotoIndexError.invalidInput) { try PhotoIndexCodec.encodeEmbedding(embedding) }
            #expect(throws: PhotoIndexError.invalidStoredData) {
                try PhotoIndexCodec.decodeEmbedding(vectorBytes(first: 1), modelID: modelID)
            }
        }
    }

    @Test
    func ocrRoundTripPreservesRussianEnglishOrderGeometryAndConfidence() throws {
        let result = PhotoOCRResult(lines: [
            PhotoOCRLine(text: "Рецепт яблочного пирога", confidence: 0.98,
                         boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.75, height: 0.1)),
            PhotoOCRLine(text: "Add cinnamon & sugar", confidence: 0.81,
                         boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.65, height: 0.1)),
        ], revision: 3, languages: ["ru-RU", "en-US"])

        #expect(try PhotoIndexCodec.decodeOCR(PhotoIndexCodec.encodeOCR(result)) == result)
        #expect(result.text == "Рецепт яблочного пирога\nAdd cinnamon & sugar")
    }

    @Test
    func emptyRecognitionIsAValidStoredSuccess() throws {
        let result = PhotoOCRResult(lines: [], revision: 3, languages: ["ru-RU", "en-US"])
        let decoded = try PhotoIndexCodec.decodeOCR(PhotoIndexCodec.encodeOCR(result))
        #expect(decoded == result)
        #expect(decoded.text.isEmpty)
    }

    @Test
    func rejectsBadBoundingBoxesOnReadAndWrite() throws {
        for box in [CGRect(x: -0.01, y: 0, width: 0.5, height: 0.5),
                    CGRect(x: 0, y: 0.8, width: 0.5, height: 0.3),
                    CGRect(x: 0, y: 0, width: 0, height: 0.5),
                    CGRect(x: 0, y: 0, width: -0.1, height: 0.5),
                    CGRect(x: CGFloat.infinity, y: 0, width: 0.5, height: 0.5)] {
            let result = resultWithLine(box: box)
            #expect(throws: PhotoIndexError.invalidInput) { try PhotoIndexCodec.encodeOCR(result) }
        }
        for replacement in ["\"x\":-0.01", "\"width\":0", "\"width\":1.5"] {
            let key = replacement.hasPrefix("\"x\"") ? "\"x\":0.1" : "\"width\":0.5"
            let valid = try PhotoIndexCodec.encodeOCR(resultWithLine())
            let malformed = String(decoding: valid, as: UTF8.self).replacingOccurrences(of: key, with: replacement)
            #expect(throws: PhotoIndexError.invalidStoredData) {
                try PhotoIndexCodec.decodeOCR(Data(malformed.utf8))
            }
        }
    }

    @Test
    func rejectsInvalidConfidenceRevisionLanguagesAndEnvelopeVersion() throws {
        for confidence in [Float(-0.1), 1.1, .nan, .infinity] {
            #expect(throws: PhotoIndexError.invalidInput) {
                try PhotoIndexCodec.encodeOCR(resultWithLine(confidence: confidence))
            }
        }
        for revision in [0, -1, 4, Int.max] {
            let result = PhotoOCRResult(lines: [], revision: revision, languages: ["ru-RU"])
            #expect(throws: PhotoIndexError.invalidInput) { try PhotoIndexCodec.encodeOCR(result) }
        }
        for languages in [[], [""], ["ru-RU", "ru-RU"]] {
            let result = PhotoOCRResult(lines: [], revision: 3, languages: languages)
            #expect(throws: PhotoIndexError.invalidInput) { try PhotoIndexCodec.encodeOCR(result) }
        }
        let valid = String(decoding: try PhotoIndexCodec.encodeOCR(resultWithLine()), as: UTF8.self)
        for (original, replacement) in [("\"formatVersion\":1", "\"formatVersion\":2"),
                                         ("\"revision\":3", "\"revision\":0"),
                                         ("\"confidence\":1", "\"confidence\":-1")] {
            let malformed = valid.replacingOccurrences(of: original, with: replacement)
            #expect(malformed != valid)
            #expect(throws: PhotoIndexError.invalidStoredData) {
                try PhotoIndexCodec.decodeOCR(Data(malformed.utf8))
            }
        }
    }

    @Test
    func rejectsUnboundedAndMalformedOCRPayloads() throws {
        for data in [Data(), Data("{}".utf8), Data("not json".utf8),
                     Data(repeating: 32, count: PhotoIndexCodec.maximumOCRBytes + 1)] {
            #expect(throws: PhotoIndexError.invalidStoredData) { try PhotoIndexCodec.decodeOCR(data) }
        }
        for text in ["", " \n", String(repeating: "a", count: 65_537)] {
            #expect(throws: PhotoIndexError.invalidInput) {
                try PhotoIndexCodec.encodeOCR(resultWithLine(text: text))
            }
        }
        let tooManyLines = PhotoOCRResult(lines: Array(repeating: resultWithLine().lines[0], count: 20_001),
                                          revision: 3, languages: ["ru-RU"])
        #expect(throws: PhotoIndexError.invalidInput) { try PhotoIndexCodec.encodeOCR(tooManyLines) }
    }

    @Test
    func ocrVersionContainsPipelineSettingsAndActualOSVersion() {
        let version = PhotoIndexPipeline.currentOCRVersion
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #expect(version.contains("pipeline-v1;vision-r3;ru-RU,en-US;accurate"))
        #expect(version.contains("tile-2048;overlap-256"))
        #expect(version.hasSuffix("ios-\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"))
    }

    private func vectorBytes(first: Float) -> Data {
        let bits = first.bitPattern
        return Data([UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8),
                     UInt8(truncatingIfNeeded: bits >> 16), UInt8(truncatingIfNeeded: bits >> 24)])
            + Data(repeating: 0, count: 511 * 4)
    }

    private func resultWithLine(text: String = "Рецепт", confidence: Float = 1,
                                box: CGRect = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1)) -> PhotoOCRResult {
        PhotoOCRResult(lines: [PhotoOCRLine(text: text, confidence: confidence, boundingBox: box)],
                       revision: 3, languages: ["ru-RU", "en-US"])
    }
}
