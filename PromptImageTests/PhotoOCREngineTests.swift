import CoreImage
import Foundation
import ImageIO
import Testing
import UIKit
@testable import PromptImage

/// All images are synthetic and in memory. Serialize Vision work to keep test memory bounded.
@Suite(.serialized)
@MainActor
struct PhotoOCREngineTests {
    @Test
    func recognizesRussianAndEnglishWithTheActualVisionEngine() async throws {
        let source = try textImage(width: 1_200, height: 480, lines: [
            ("Рецепт яблочного пирога", 60),
            ("Add cinnamon and sugar", 190),
        ])

        let result = try await PhotoOCREngine().recognize(source)

        #expect(result.text.localizedCaseInsensitiveContains("яблочного пирога"))
        #expect(result.text.localizedCaseInsensitiveContains("cinnamon"))
        #expect(result.text.localizedCaseInsensitiveContains("sugar"))
        #expect(result.revision == 3)
        #expect(result.languages == ["ru-RU", "en-US"])
        #expect(result.lines.count >= 2)
        #expect(result.lines.allSatisfy { $0.confidence > 0 && $0.confidence <= 1 })
        expectNormalizedBoxes(result)
        let russian = try #require(result.lines.firstIndex { $0.text.contains("пирога") })
        let english = try #require(result.lines.firstIndex { $0.text.localizedCaseInsensitiveContains("cinnamon") })
        #expect(russian < english)
        #expect(result.lines[russian].boundingBox.midY > result.lines[english].boundingBox.midY)
    }

    @Test
    func blankImageProducesAnEmptySuccessfulResult() async throws {
        let source = try textImage(width: 640, height: 480, lines: [])
        let result = try await PhotoOCREngine().recognize(source)

        #expect(result.lines.isEmpty)
        #expect(result.text.isEmpty)
    }

    @Test
    func recognizesPhysicallySidewaysTextAfterApplyingPhotoKitOrientation() async throws {
        let upright = try textImage(width: 1_000, height: 320, lines: [("CINNAMON RECIPE", 90)])
        let image = try #require(UIImage(data: upright.data)?.cgImage)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 1_000), format: format)
        let sideways = renderer.pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 1_000))
            // Rotate the pixels counterclockwise. The source's .right must undo it.
            UIImage(cgImage: image, scale: 1, orientation: .left)
                .draw(in: CGRect(x: 0, y: 0, width: 320, height: 1_000))
        }

        let result = try await PhotoOCREngine().recognize(
            PhotoOCRSource(data: sideways, orientation: .right)
        )

        #expect(result.text.localizedCaseInsensitiveContains("CINNAMON RECIPE"))
        expectNormalizedBoxes(result)
    }

    @Test
    func tallScreenshotPreservesWholeImageAndMergesOverlapLinesExactlyOnce() async throws {
        // At this height the overlap midpoints are at y=5504, 3712, and 1920 from
        // the bottom. The drawn boundary lines straddle those positions.
        let source = try textImage(width: 1_200, height: 6_000, lines: [
            ("TOP RECIPE", 80),
            ("FIRST TILE BOUNDARY", 468),
            ("REPEATED INGREDIENT", 1_000),
            ("SECOND TILE BOUNDARY", 2_260),
            ("MIDDLE DIRECTIONS", 2_930),
            ("THIRD TILE BOUNDARY", 4_052),
            ("REPEATED INGREDIENT", 4_700),
            ("BOTTOM NOTES", 5_820),
        ])

        let result = try await PhotoOCREngine().recognize(source)

        for phrase in ["TOP RECIPE", "FIRST TILE BOUNDARY", "SECOND TILE BOUNDARY",
                       "MIDDLE DIRECTIONS", "THIRD TILE BOUNDARY", "BOTTOM NOTES"] {
            #expect(result.lines.filter { $0.text.localizedCaseInsensitiveContains(phrase) }.count == 1)
        }
        let repeated = result.lines.filter { $0.text.localizedCaseInsensitiveContains("REPEATED INGREDIENT") }
        #expect(repeated.count == 2)
        if repeated.count == 2 {
            #expect(abs(repeated[0].boundingBox.midY - repeated[1].boundingBox.midY) > 0.5)
        }
        let top = try #require(result.lines.first { $0.text.localizedCaseInsensitiveContains("TOP RECIPE") })
        let middle = try #require(result.lines.first { $0.text.localizedCaseInsensitiveContains("MIDDLE DIRECTIONS") })
        let bottom = try #require(result.lines.first { $0.text.localizedCaseInsensitiveContains("BOTTOM NOTES") })
        #expect(top.boundingBox.midY > 0.95)
        #expect((0.45...0.55).contains(middle.boundingBox.midY))
        #expect(bottom.boundingBox.midY < 0.05)
        #expect(zip(result.lines, result.lines.dropFirst()).allSatisfy { pair in
            pair.0.boundingBox.midY >= pair.1.boundingBox.midY
        })
        expectNormalizedBoxes(result)
    }

    @Test
    func decodingAppliesAllEightOrientationsAndKeepsTheEntireImage() throws {
        let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255],
                                 [0, 0, 255, 255], [255, 255, 0, 255]]
        let data = try encodedImage(width: 80, height: 40) { x, y in
            colors[(y < 20 ? 0 : 2) + (x < 40 ? 0 : 1)]
        }
        // Expected colors at top-left, top-right, bottom-left, bottom-right.
        let expectedCorners = [
            [0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1],
            [0, 2, 1, 3], [2, 0, 3, 1], [3, 1, 2, 0], [1, 3, 0, 2],
        ]
        let context = CIContext(options: [.cacheIntermediates: false])
        for raw in 1...8 {
            let orientation = try #require(CGImagePropertyOrientation(rawValue: UInt32(raw)))
            let image = try PhotoOCRImage.decode(PhotoOCRSource(data: data, orientation: orientation))
            let width = raw <= 4 ? 80 : 40
            let height = raw <= 4 ? 40 : 80
            #expect(image.extent == CGRect(x: 0, y: 0, width: width, height: height))
            let points = [(4, height - 5), (width - 5, height - 5), (4, 4), (width - 5, 4)]
            for (index, point) in points.enumerated() {
                let actual = pixel(image, x: point.0, y: point.1, context: context)
                let expected = colors[expectedCorners[raw - 1][index]]
                #expect(zip(actual, expected).allSatisfy { pair in abs(Int(pair.0) - Int(pair.1)) <= 1 })
            }
        }
    }

    @Test
    func explicitOrientationOverridesEmbeddedMetadataAndTransparencyBecomesWhite() throws {
        let data = try encodedImage(width: 80, height: 40, orientation: .down) { x, _ in
            x < 40 ? [255, 0, 0, 255] : [0, 0, 0, 0]
        }
        let image = try PhotoOCRImage.decode(PhotoOCRSource(data: data, orientation: .up))
        let context = CIContext(options: [.cacheIntermediates: false])

        #expect(pixel(image, x: 4, y: 20, context: context) == [255, 0, 0, 255])
        #expect(pixel(image, x: 75, y: 20, context: context) == [255, 255, 255, 255])
    }

    @Test
    func thumbnailGeometryRetainsAspectRatioWithoutUpscalingAndCapsDecodedWork() throws {
        #expect(try PhotoOCRImage.thumbnailEdge(width: 100, height: 200) == 200)
        #expect(try PhotoOCRImage.thumbnailEdge(width: 4_000, height: 3_000) == 2_133)
        #expect(try PhotoOCRImage.thumbnailEdge(width: 3_000, height: 4_000) == 2_133)
        #expect(try PhotoOCRImage.thumbnailEdge(width: 1_200, height: 6_000) == 6_000)
        // The area cap, rather than the short edge, limits this very tall screenshot.
        #expect(try PhotoOCRImage.thumbnailEdge(width: 1_600, height: 20_000) == 17_320)
    }

    @Test
    func overlappingTilesCoverTheImageIncludingBothAxesAndMapBackToImageCoordinates() {
        let width = 4_500
        let height = 6_000
        let tiles = PhotoOCRImage.tiles(width: width, height: height)
        #expect(tiles.count == 12)
        #expect(tiles.allSatisfy {
            $0.region.width <= 2_048 && $0.region.height <= 2_048
        })
        #expect(Set(tiles.map { $0.region.minX }) == Set([CGFloat(0), 1_792, 3_584]))
        #expect(Set(tiles.map { $0.region.minY }) == Set([CGFloat(0), 1_792, 3_584, 5_376]))
        let imageSize = CGSize(width: width, height: height)
        let xs: [CGFloat] = [0.5, 1_791.5, 1_792, 1_920, 2_047.5, 2_048, 3_584, 3_712, 3_840, 4_499.5]
        let ys: [CGFloat] = [0.5, 1_791.5, 1_792, 1_920, 2_047.5, 2_048, 3_584, 3_712, 5_376, 5_504, 5_999.5]
        for x in xs {
            for y in ys {
                let globalBox = CGRect(x: x - 0.25, y: y - 0.25, width: 0.5, height: 0.5)
                let coveringTiles = tiles.filter { $0.region.contains(CGPoint(x: x, y: y)) }
                #expect(!coveringTiles.isEmpty)
                for tile in coveringTiles {
                    let localBox = CGRect(x: (globalBox.minX - tile.region.minX) / tile.region.width,
                                          y: (globalBox.minY - tile.region.minY) / tile.region.height,
                                          width: globalBox.width / tile.region.width,
                                          height: globalBox.height / tile.region.height)
                    let mapped = tile.map(localBox, imageSize: imageSize)
                    #expect(abs(mapped.midX - x / CGFloat(width)) < 0.000_001)
                    #expect(abs(mapped.midY - y / CGFloat(height)) < 0.000_001)
                    #expect(abs(mapped.width - 0.5 / CGFloat(width)) < 0.000_001)
                    #expect(abs(mapped.height - 0.5 / CGFloat(height)) < 0.000_001)
                }
            }
        }
        #expect(tiles.filter { $0.region.contains(CGPoint(x: 1_920, y: 1_920)) }.count == 4)
    }

    @Test
    func rejectsInvalidInputAndDimensionsBeforeUnsafeDecoding() throws {
        for data in [Data(), Data("not an image".utf8)] {
            do {
                _ = try PhotoOCRImage.decode(PhotoOCRSource(data: data, orientation: .up))
                Issue.record("Invalid bytes should be rejected")
            } catch PhotoOCRError.invalidImage {}
        }
        for (width, height) in [(0, 20), (20, -1)] {
            do {
                _ = try PhotoOCRImage.thumbnailEdge(width: width, height: height)
                Issue.record("Nonpositive dimensions should be rejected")
            } catch PhotoOCRError.invalidImage {}
        }
        for (width, height) in [(65_537, 1), (10_001, 10_000), (Int.max, Int.max)] {
            do {
                _ = try PhotoOCRImage.thumbnailEdge(width: width, height: height)
                Issue.record("Dimensions above the safety limits should be rejected")
            } catch PhotoOCRError.imageTooLarge {}
        }
        let oversized = PhotoOCRSource(data: Data(repeating: 0, count: 64 * 1_024 * 1_024 + 1),
                                       orientation: .up)
        do {
            _ = try PhotoOCRImage.decode(oversized)
            Issue.record("Encoded bytes above the cap should be rejected before decoding")
        } catch PhotoOCRError.imageTooLarge {}
    }

    @Test
    func cancellationWinsBeforeImageDecodingOrVisionSetup() async throws {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await PhotoOCREngine().recognize(PhotoOCRSource(data: Data(), orientation: .up))
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("A cancelled recognition should not produce a result")
        } catch is CancellationError {
            // This must be cancellation, rather than an error from the invalid image.
        }
    }

    private func expectNormalizedBoxes(_ result: PhotoOCRResult) {
        #expect(result.lines.allSatisfy { line in
            let box = line.boundingBox
            return box.width > 0 && box.height > 0 && box.minX >= 0 && box.minY >= 0
                && box.maxX <= 1.000_001 && box.maxY <= 1.000_001
        })
    }

    private func textImage(width: Int, height: Int, lines: [(String, CGFloat)]) throws -> PhotoOCRSource {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let data = renderer.pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 48),
                .foregroundColor: UIColor.black,
            ]
            for (text, y) in lines {
                (text as NSString).draw(at: CGPoint(x: 60, y: y), withAttributes: attributes)
            }
        }
        return PhotoOCRSource(data: data, orientation: .up)
    }

    private func encodedImage(width: Int, height: Int,
                              orientation: CGImagePropertyOrientation = .up,
                              pixel: (Int, Int) -> [UInt8]) throws -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width { bytes.append(contentsOf: pixel(x, y)) }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false,
                                        intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func pixel(_ image: CIImage, x: Int, y: Int, context: CIContext) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 4,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return bytes
    }
}
