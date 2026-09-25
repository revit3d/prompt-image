import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Testing
import zlib
@testable import PromptImage

struct CLIPImagePreprocessorTests {
    @Test
    func returnsNormalizedRGBInNCHWOrder() throws {
        let data = try encodedImage(width: 224, height: 224) { _, _ in [64, 128, 255] }
        let result = try CLIPImagePreprocessor().prepare(data: data)

        #expect(result.shape.map(\.intValue) == [1, 3, 224, 224])
        #expect(result.dataType == .float32)
        for channel in 0..<3 {
            for point in [(0, 0), (51, 123), (223, 223)] {
                #expect(abs(value(result, channel: channel, x: point.0, y: point.1)
                            - normalized([64, 128, 255][channel], channel: channel)) < 0.000_001)
            }
        }
    }

    @Test
    func appliesEveryOrientationBeforePreprocessing() throws {
        let colors: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [128, 128, 128]]
        let data = try encodedImage(width: 224, height: 224) { x, y in
            colors[(y < 112 ? 0 : 2) + (x < 112 ? 0 : 1)]
        }
        let expectedCorners = [
            [0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1],
            [0, 2, 1, 3], [2, 0, 3, 1], [3, 1, 2, 0], [1, 3, 0, 2],
        ]
        let points = [(20, 20), (203, 20), (20, 203), (203, 203)]
        for raw in 1...8 {
            let orientation = try #require(CGImagePropertyOrientation(rawValue: UInt32(raw)))
            let result = try CLIPImagePreprocessor().prepare(data: data, orientation: orientation)
            for corner in 0..<4 {
                for channel in 0..<3 {
                    let expected = normalized(Int(colors[expectedCorners[raw - 1][corner]][channel]), channel: channel)
                    #expect(abs(value(result, channel: channel, x: points[corner].0, y: points[corner].1)
                                - expected) < 0.000_001)
                }
            }
        }
    }

    @Test
    func explicitPhotoKitOrientationOverridesEmbeddedOrientation() throws {
        let data = try encodedImage(width: 224, height: 224, orientation: .down) { x, _ in
            x < 112 ? [255, 0, 0] : [0, 0, 255]
        }
        let embedded = try CLIPImagePreprocessor().prepare(data: data)
        let overridden = try CLIPImagePreprocessor().prepare(data: data, orientation: .up)

        #expect(abs(value(embedded, channel: 0, x: 10, y: 10) - normalized(0, channel: 0)) < 0.000_001)
        #expect(abs(value(overridden, channel: 0, x: 10, y: 10) - normalized(255, channel: 0)) < 0.000_001)
    }

    @Test
    func resizeFloorsLongEdgeAndCenterCropUsesBankersRounding() throws {
        let landscape = try CLIPImagePreprocessor.resizeGeometry(width: 321, height: 241)
        #expect(landscape == .init(width: 298, height: 224, cropX: 37, cropY: 0))
        let portrait = try CLIPImagePreprocessor.resizeGeometry(width: 241, height: 321)
        #expect(portrait == .init(width: 224, height: 298, cropX: 0, cropY: 37))
        #expect(try CLIPImagePreprocessor.resizeGeometry(width: 225, height: 224).cropX == 0)
        #expect(try CLIPImagePreprocessor.resizeGeometry(width: 227, height: 224).cropX == 2)
        #expect(try CLIPImagePreprocessor.resizeGeometry(width: 229, height: 224).cropX == 2)
    }

    @Test
    func expandsGrayscaleIntoEachRGBChannel() throws {
        let data = try encodedImage(width: 224, height: 224, grayscale: true) { _, _ in [37] }
        let result = try CLIPImagePreprocessor().prepare(data: data)
        for channel in 0..<3 {
            #expect(abs(value(result, channel: channel, x: 111, y: 87)
                        - normalized(37, channel: channel)) < 0.000_001)
        }
    }

    @Test(arguments: ["public.jpeg", "public.tiff"])
    func convertsEightBitCMYKWithPillowRounding(format: String) throws {
        let data = try encodedImage(width: 224, height: 224, cmyk: true, format: format as CFString) {
            _, _ in [64, 128, 192, 80]
        }
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.colorSpace?.model == .cmyk)
        let result = try CLIPImagePreprocessor().prepare(data: data)
        // Pillow converts C/M/Y/K=(64,128,192,80) to RGB=(131,87,43).
        for channel in 0..<3 {
            let expected = normalized([131, 87, 43][channel], channel: channel)
            let tolerance: Float = format == "public.jpeg"
                ? abs(normalized(2, channel: channel) - normalized(0, channel: channel)) : 0.000_001
            #expect(abs(value(result, channel: channel, x: 111, y: 87) - expected) <= tolerance)
        }
    }

    @Test(.enabled(if: (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains("public.heic") == true,
                   "The current ImageIO runtime must provide an HEIC encoder"))
    func acceptsEightBitHEICFromTheSystemEncoder() throws {
        let data = try encodedImage(width: 256, height: 256, format: "public.heic" as CFString) { _, _ in [64, 128, 192] }
        let result = try CLIPImagePreprocessor().prepare(data: data)
        for channel in 0..<3 {
            // HEIC uses a lossy YCbCr codec: allow four decoded RGB levels, not a tensor-
            // equality promise between Apple's decoder and a separate reference codec.
            let tolerance = abs(normalized(4, channel: channel) - normalized(0, channel: channel))
            #expect(abs(value(result, channel: channel, x: 100, y: 100)
                        - normalized([64, 128, 192][channel], channel: channel)) <= tolerance)
        }
    }

    @Test
    func preservesStraightAlphaRGBWhenResizeIsUnnecessary() throws {
        // Independent straight-alpha PNG from Pillow 11.3: 224×224 RGB=(80,160,240),
        // alpha=0 for x<112 and 128 otherwise. ImageIO's PNG encoder quantizes RGB
        // through premultiplication, so it cannot construct this preservation fixture.
        let data = try #require(Data(base64Encoded: """
            iVBORw0KGgoAAAANSUhEUgAAAOAAAADgCAYAAAAaLWrhAAACkklEQVR4nO3TQQ2AMAAEwYJCJCGlEpFQD/SxaTLzv+Q+ez3zGxzt
            rQ/w372xBTYJEEIChJAAISRACAkQQgKEkAAhJEAICRBCAoSQACEkQAgJEEIChJAAISRACAkQQgKEkAAhJEAICRBCAoSQACEkQAgJ
            EEIChJAAISRACAkQQgKEkAAhJEAICRBCAoSQACEkQAgJEEIChJAAISRACAkQQgKEkAAhJEAICRBCAoSQACEkQAgJEEIChJAAISRA
            CAkQQgKEkAAhJEAICRBCAoSQACEkQAgJEEIChJAAISRACAkQQgKEkAAhJEAICRBCAoSQACEkQAgJEEIChJAAISRACAkQQgKEkAAh
            JEAICRBCAoSQACEkQAgJEEIChJAAISRACAkQQgKEkAAhJEAICRBCAoSQACEkQAgJEEIChJAAISRACAkQQgKEkAAhJEAICRBCAoSQ
            ACEkQAgJEEIChJAAISRACAkQQgKEkAAhJEAICRBCAoSQACEkQAgJEEIChJAAISRACAkQQgKEkAAhJEAICRBCAoSQACEkQAgJEEIC
            hJAAISRACAkQQgKEkAAhJEAICRBCAoSQACEkQAgJEEIChJAAISRACAkQQgKEkAAhJEAICRBCAoSQACEkQAgJEEIChJAAISRACAkQ
            QgKEkAAhJEAICRBCAoSQACEkQAgJEEIChJAAISRACAkQQgKEkAAhJEAICRBCAoSQACEkQAgJEEIChJAAISRACAkQQgKEkAAhJEAI
            CRBCAoSQACEkQAgJEEIChJAAISRACAkQQgKEkAAhJEAICRBCAoSQACEkQAgJEEIChJAAISRACAkQQgKEkAAhJEAICRBCAoSQACEk
            QAgJEEIChJAAISRACAkQQgKE0VmYFwQgeuXcwAAAAABJRU5ErkJggg==
            """, options: .ignoreUnknownCharacters))
        let result = try CLIPImagePreprocessor().prepare(data: data)
        for channel in 0..<3 {
            for x in [10, 200] {
                #expect(abs(value(result, channel: channel, x: x, y: 100)
                            - normalized([80, 160, 240][channel], channel: channel)) < 0.000_001)
            }
        }
    }

    @Test
    func resizingAlphaMatchesPillowsPremultiplicationRounding() throws {
        let data = try encodedImage(width: 17, height: 13, alpha: true) { _, _ in [80, 160, 240, 128] }
        let result = try CLIPImagePreprocessor().prepare(data: data)
        for channel in 0..<3 {
            #expect(abs(value(result, channel: channel, x: 100, y: 100)
                        - normalized([79, 159, 239][channel], channel: channel)) < 0.000_001)
        }
        let transparent = try encodedImage(width: 17, height: 13, alpha: true) { _, _ in [80, 160, 240, 0] }
        let zero = try CLIPImagePreprocessor().prepare(data: transparent)
        for channel in 0..<3 {
            #expect(abs(value(zero, channel: channel, x: 100, y: 100)
                        - normalized(0, channel: channel)) < 0.000_001)
        }
    }

    @Test
    func rejectsInvalidImagesAndUnsafeDimensions() throws {
        #expect(throws: CLIPImagePreprocessingError.invalidImage) {
            try CLIPImagePreprocessor().prepare(data: Data())
        }
        #expect(throws: CLIPImagePreprocessingError.invalidImage) {
            try CLIPImagePreprocessor().prepare(data: Data("not an image".utf8))
        }
        #expect(throws: CLIPImagePreprocessingError.invalidImage) {
            try CLIPImagePreprocessor.resizeGeometry(width: 0, height: 12)
        }
        #expect(throws: CLIPImagePreprocessingError.imageTooLarge) {
            try CLIPImagePreprocessor.resizeGeometry(width: 32_769, height: 1)
        }
        #expect(throws: CLIPImagePreprocessingError.imageTooLarge) {
            try CLIPImagePreprocessor.resizeGeometry(width: 10_000, height: 10_000)
        }
    }

    @Test(arguments: [false, true])
    func alphaPNGDecoderHandlesAllFiltersAndAdam7(interlaced: Bool) throws {
        let fixture = try rawAlphaPNG(interlaced: interlaced)
        let decoded = try CLIPPNGDecoder.decodeAlphaPNG(fixture.encoded)
        let result = try #require(decoded)
        #expect(result.width == 9)
        #expect(result.height == 11)
        #expect(result.channels == 4)
        #expect(result.pixels == fixture.pixels)
    }

    @Test
    func alphaPNGRejectsCRCTruncationAndExcessInflatedData() throws {
        let valid = try rawAlphaPNG().encoded
        var corrupted = valid
        corrupted[corrupted.count - 1] ^= 1
        #expect(throws: CLIPImagePreprocessingError.invalidImage) {
            try CLIPPNGDecoder.decodeAlphaPNG(corrupted)
        }
        #expect(throws: CLIPImagePreprocessingError.invalidImage) {
            try CLIPPNGDecoder.decodeAlphaPNG(valid.dropLast(5))
        }
        let excessive = try rawAlphaPNG(extraInflatedByte: true).encoded
        #expect(throws: CLIPImagePreprocessingError.invalidImage) {
            try CLIPPNGDecoder.decodeAlphaPNG(excessive)
        }
        let malformedFilter = try rawAlphaPNG(invalidFilter: true).encoded
        #expect(throws: CLIPImagePreprocessingError.invalidImage) {
            try CLIPPNGDecoder.decodeAlphaPNG(malformedFilter)
        }
        let excessiveDimensions = try rawAlphaPNG(advertisedWidth: 32_769).encoded
        #expect(throws: CLIPImagePreprocessingError.imageTooLarge) {
            try CLIPPNGDecoder.decodeAlphaPNG(excessiveDimensions)
        }
    }

    @Test
    func cancellationStopsBeforeDecoding() async throws {
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try CLIPImagePreprocessor().prepare(data: Data())
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled preprocessing task should not produce a tensor")
        } catch is CancellationError {
            // Expected rather than the invalid-image error from decoding the empty data.
        }
    }

    private func normalized(_ byte: Int, channel: Int) -> Float {
        let means: [Float] = [0.48145466, 0.4578275, 0.40821073]
        let deviations: [Float] = [0.26862954, 0.26130258, 0.27577711]
        return (Float(byte) / 255 - means[channel]) / deviations[channel]
    }

    private func value(_ tensor: MLMultiArray, channel: Int, x: Int, y: Int) -> Float {
        tensor[channel * 224 * 224 + y * 224 + x].floatValue
    }

    /// Small independent PNG writer for decoder boundaries. No private images or files.
    /// Expected pixels are generated first; each pass/filter must reconstruct those bytes.
    private func rawAlphaPNG(interlaced: Bool = false, extraInflatedByte: Bool = false,
                             invalidFilter: Bool = false, advertisedWidth: Int? = nil) throws -> (encoded: Data, pixels: Data) {
        let width = 9
        let height = 11
        let pixels = (0..<(width * height)).flatMap { index -> [UInt8] in
            let x = index % width
            let y = index / width
            return [UInt8(x * 27), UInt8(y * 23), UInt8((x * 13 + y * 17) % 256), UInt8((x + y) % 3 * 127)]
        }
        let passes = interlaced
            ? [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
               (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
            : [(0, 0, 1, 1)]
        var scanlines: [UInt8] = []
        for (startX, startY, stepX, stepY) in passes {
            let columns = Array(stride(from: startX, to: width, by: stepX))
            var previous = [UInt8](repeating: 0, count: columns.count * 4)
            for (rowIndex, y) in stride(from: startY, to: height, by: stepY).enumerated() {
                let row = columns.flatMap { x in Array(pixels[((y * width + x) * 4)..<((y * width + x + 1) * 4)]) }
                let filter = rowIndex % 5
                scanlines.append(UInt8(filter))
                for index in row.indices {
                    let left = index >= 4 ? Int(row[index - 4]) : 0
                    let above = Int(previous[index])
                    let upperLeft = index >= 4 ? Int(previous[index - 4]) : 0
                    let predictor: Int
                    switch filter {
                    case 0: predictor = 0
                    case 1: predictor = left
                    case 2: predictor = above
                    case 3: predictor = (left + above) / 2
                    default:
                        let estimate = left + above - upperLeft
                        let choices = [(left, abs(estimate - left)), (above, abs(estimate - above)),
                                       (upperLeft, abs(estimate - upperLeft))]
                        predictor = choices.enumerated().min { lhs, rhs in
                            lhs.element.1 == rhs.element.1 ? lhs.offset < rhs.offset : lhs.element.1 < rhs.element.1
                        }!.element.0
                    }
                    scanlines.append(row[index] &- UInt8(predictor))
                }
                previous = row
            }
        }
        if invalidFilter { scanlines[0] = 5 }
        if extraInflatedByte { scanlines.append(42) }
        var compressed = [UInt8](repeating: 0, count: Int(compressBound(uLong(scanlines.count))))
        var compressedCount = uLongf(compressed.count)
        let status = compressed.withUnsafeMutableBufferPointer { output in
            scanlines.withUnsafeBufferPointer { input in
                compress2(output.baseAddress, &compressedCount, input.baseAddress, uLong(input.count), Z_BEST_COMPRESSION)
            }
        }
        #expect(status == Z_OK)
        func bigEndian(_ value: UInt32) -> [UInt8] {
            [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
        }
        func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let content = Array(type.utf8) + payload
            let checksum = content.withUnsafeBufferPointer { crc32(0, $0.baseAddress, uInt($0.count)) }
            return bigEndian(UInt32(payload.count)) + content + bigEndian(UInt32(checksum))
        }
        let header = bigEndian(UInt32(advertisedWidth ?? width)) + bigEndian(UInt32(height)) + [8, 6, 0, 0, interlaced ? 1 : 0]
        let idat = Array(compressed.prefix(Int(compressedCount)))
        // Split the zlib stream across IDAT chunks to exercise streaming boundaries.
        let split = idat.count / 2
        let encoded = [137, 80, 78, 71, 13, 10, 26, 10]
            + chunk("IHDR", header) + chunk("IDAT", Array(idat[..<split]))
            + chunk("IDAT", Array(idat[split...])) + chunk("IEND", [])
        return (Data(encoded), Data(pixels))
    }

    private func encodedImage(width: Int, height: Int, alpha: Bool = false, grayscale: Bool = false, cmyk: Bool = false,
                     format: CFString = "public.png" as CFString,
                     orientation: CGImagePropertyOrientation = .up,
                     pixel: (Int, Int) -> [UInt8]) throws -> Data {
        let channels = (cmyk ? 4 : (grayscale ? 1 : 3)) + (alpha ? 1 : 0)
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * channels)
        for y in 0..<height {
            for x in 0..<width { pixels.append(contentsOf: pixel(x, y)) }
        }
        let space = cmyk ? CGColorSpaceCreateDeviceCMYK()
            : (grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB())
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
                                        bitsPerPixel: channels * 8, bytesPerRow: width * channels,
                                        space: space,
                                        bitmapInfo: CGBitmapInfo(rawValue: alpha ? CGImageAlphaInfo.last.rawValue
                                                                               : CGImageAlphaInfo.none.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false,
                                        intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, format, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation.rawValue,
                                                       kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
