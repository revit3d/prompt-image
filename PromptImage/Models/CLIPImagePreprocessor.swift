import CoreGraphics
import CoreML
import Foundation
import ImageIO

nonisolated enum CLIPImagePreprocessingError: Error, Equatable {
    case invalidImage
    case unsupportedPixelFormat
    case imageTooLarge
    case invalidOrientation
}

/// ImageIO decodes the first still image without applying an ICC color transform,
/// matching Pillow's `convert("RGB")` convention.
/// Supports 8-bit RGB and grayscale, including alpha, and CMYK. CMYK stays in its
/// original four channels through resizing, then uses Pillow's RGB conversion.
/// RAW/HDR and unsupported decoded layouts fail rather than changing the model's input.
nonisolated struct CLIPImagePreprocessor {
    static let imageSize = 224
    static let maximumPixelCount = 50_000_000
    static let maximumDimension = 32_768
    static let maximumEncodedBytes = 100 * 1_024 * 1_024
    static let maximumDecodedBytes = 256 * 1_024 * 1_024

    private static let means: [Float] = [0.48145466, 0.4578275, 0.40821073]
    private static let deviations: [Float] = [0.26862954, 0.26130258, 0.27577711]
    private static let precision = 22
    private static let coefficientScale = 1 << precision

    /// A PhotoKit orientation can override embedded EXIF. Orientation is applied once,
    /// before shorter-edge resizing and center cropping. No thumbnail or network API is used.
    func prepare(data: Data, orientation: CGImagePropertyOrientation? = nil) throws -> MLMultiArray {
        try Task.checkCancellation()
        guard data.count <= Self.maximumEncodedBytes else {
            throw CLIPImagePreprocessingError.imageTooLarge
        }
        let options = [kCGImageSourceShouldCache: false, kCGImageSourceShouldAllowFloat: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw CLIPImagePreprocessingError.invalidImage
        }
        try Self.validateDimensions(width: width, height: height)
        let selectedOrientation: CGImagePropertyOrientation
        if let orientation {
            selectedOrientation = orientation
        } else {
            let value = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            guard let embedded = CGImagePropertyOrientation(rawValue: value) else {
                throw CLIPImagePreprocessingError.invalidOrientation
            }
            selectedOrientation = embedded
        }
        let decoded: DecodedImage
        let decodedWidth: Int
        let decodedHeight: Int
        if let png = try CLIPPNGDecoder.decodeAlphaPNG(data) {
            decoded = DecodedImage(png: png)
            decodedWidth = png.width
            decodedHeight = png.height
        } else {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
                throw CLIPImagePreprocessingError.invalidImage
            }
            decoded = try DecodedImage(image: image)
            decodedWidth = image.width
            decodedHeight = image.height
        }
        try Task.checkCancellation()
        let swapsAxes = selectedOrientation.rawValue >= 5
        let orientedWidth = swapsAxes ? decodedHeight : decodedWidth
        let orientedHeight = swapsAxes ? decodedWidth : decodedHeight
        let geometry = try Self.resizeGeometry(width: orientedWidth, height: orientedHeight)
        let needsResize = geometry.width != orientedWidth || geometry.height != orientedHeight
        let alphaResize = needsResize && decoded.alphaIndex != nil
        let channels = alphaResize || decoded.cmykInverted != nil ? 4 : 3

        // Generate only the 224 columns/rows retained by the center crop. The samples and
        // rounding are identical to a full resize, without a panorama-sized output buffer.
        let horizontal = Self.coefficients(input: orientedWidth, output: geometry.width, start: geometry.cropX)
        let vertical = Self.coefficients(input: orientedHeight, output: geometry.height, start: geometry.cropY)
        let firstRow = vertical[0].start
        let endRow = vertical.last!.end
        var intermediate = [UInt8](repeating: 0, count: (endRow - firstRow) * Self.imageSize * channels)
        let sourceBytes = CFDataGetBytePtr(decoded.data)!

        for sourceY in firstRow..<endRow {
            try Task.checkCancellation()
            for outputX in 0..<Self.imageSize {
                let filter = horizontal[outputX]
                var sums = SIMD4<Int>(repeating: Self.coefficientScale / 2)
                for sample in filter.weights.indices {
                    let sourceX = filter.start + sample
                    let point = Self.sourcePoint(x: sourceX, y: sourceY, width: decodedWidth,
                                                 height: decodedHeight, orientation: selectedOrientation)
                    let offset = point.y * decoded.bytesPerRow + point.x * decoded.bytesPerPixel
                    let alpha = decoded.alphaIndex.map { Int(sourceBytes[offset + $0]) } ?? 255
                    guard !decoded.premultiplied || alpha == 255 else {
                        // Non-PNG premultiplied sources cannot preserve invisible RGB or
                        // recover quantized translucent values from the system decoder.
                        throw CLIPImagePreprocessingError.unsupportedPixelFormat
                    }
                    for channel in 0..<channels {
                        var value: Int
                        if let inverted = decoded.cmykInverted {
                            value = Int(sourceBytes[offset + decoded.colorIndices[channel]])
                            if inverted[channel] { value = 255 - value }
                        } else if channel == 3 {
                            value = alpha
                        } else {
                            value = Int(sourceBytes[offset + decoded.colorIndices[channel]])
                            if alphaResize {
                                value = (value * alpha + 127) / 255
                            }
                        }
                        sums[channel] += value * filter.weights[sample]
                    }
                }
                let outputOffset = ((sourceY - firstRow) * Self.imageSize + outputX) * channels
                for channel in 0..<channels {
                    intermediate[outputOffset + channel] = Self.roundedByte(sums[channel])
                }
            }
        }

        let tensor = try MLMultiArray(shape: [1, 3, 224, 224], dataType: .float32)
        let result = tensor.dataPointer.bindMemory(to: Float.self, capacity: tensor.count)
        for outputY in 0..<Self.imageSize {
            try Task.checkCancellation()
            let filter = vertical[outputY]
            for outputX in 0..<Self.imageSize {
                var sums = SIMD4<Int>(repeating: Self.coefficientScale / 2)
                for sample in filter.weights.indices {
                    let offset = ((filter.start + sample - firstRow) * Self.imageSize + outputX) * channels
                    for channel in 0..<channels {
                        sums[channel] += Int(intermediate[offset + channel]) * filter.weights[sample]
                    }
                }
                let alpha = alphaResize ? Int(Self.roundedByte(sums[3])) : 255
                for channel in 0..<3 {
                    var value = Int(Self.roundedByte(sums[channel]))
                    if decoded.cmykInverted != nil {
                        // Pillow 11.3 Convert.c cmyk2rgb: subtract the rounded CMY
                        // contribution from 255-K, after resizing all four channels.
                        let nonBlack = 255 - Int(Self.roundedByte(sums[3]))
                        value = nonBlack - (value * nonBlack + 127) / 255
                    } else if alphaResize {
                        // Pillow preserves the filtered channels at zero alpha. Bicubic
                        // ringing can leave a nonzero channel even when alpha rounds to 0.
                        value = alpha == 0 ? value : min(255, 255 * value / alpha)
                    }
                    let offset = channel * Self.imageSize * Self.imageSize + outputY * Self.imageSize + outputX
                    result[offset] = (Float(value) / 255 - Self.means[channel]) / Self.deviations[channel]
                }
            }
        }
        return tensor
    }

    /// torchvision integer Resize floors the long edge; CenterCrop rounds ties to even.
    static func resizeGeometry(width: Int, height: Int) throws -> ResizeGeometry {
        try validateDimensions(width: width, height: height)
        let resizedWidth = width <= height ? imageSize : imageSize * width / height
        let resizedHeight = height <= width ? imageSize : imageSize * height / width
        return ResizeGeometry(width: resizedWidth, height: resizedHeight,
                              cropX: Int((Double(resizedWidth - imageSize) / 2).rounded(.toNearestOrEven)),
                              cropY: Int((Double(resizedHeight - imageSize) / 2).rounded(.toNearestOrEven)))
    }

    struct ResizeGeometry: Equatable {
        let width: Int
        let height: Int
        let cropX: Int
        let cropY: Int
    }

    private static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw CLIPImagePreprocessingError.invalidImage }
        guard width <= maximumDimension, height <= maximumDimension,
              width <= maximumPixelCount / height else {
            throw CLIPImagePreprocessingError.imageTooLarge
        }
    }

    private struct DecodedImage {
        let data: CFData
        let bytesPerRow: Int
        let bytesPerPixel: Int
        let colorIndices: [Int]
        let alphaIndex: Int?
        let premultiplied: Bool
        /// Per-channel decode inversion; Adobe CMYK JPEGs commonly store inverted values.
        let cmykInverted: [Bool]?

        init(png: CLIPPNGDecoder.Image) {
            data = png.pixels as CFData
            bytesPerRow = png.width * png.channels
            bytesPerPixel = png.channels
            colorIndices = png.channels == 4 ? [0, 1, 2] : [0, 0, 0]
            alphaIndex = png.channels - 1
            premultiplied = false
            cmykInverted = nil
        }

        init(image: CGImage) throws {
            try validateDimensions(width: image.width, height: image.height)
            guard image.bitsPerComponent == 8, !image.bitmapInfo.contains(.floatComponents),
                  let model = image.colorSpace?.model,
                  model == .rgb || model == .monochrome || model == .cmyk else {
                throw CLIPImagePreprocessingError.unsupportedPixelFormat
            }
            let isCMYK = model == .cmyk
            let colorCount = isCMYK ? 4 : (model == .rgb ? 3 : 1)
            if isCMYK {
                guard image.alphaInfo == .none else { throw CLIPImagePreprocessingError.unsupportedPixelFormat }
                if let decode = image.decode {
                    cmykInverted = try (0..<4).map { channel in
                        let lower = decode[channel * 2]
                        let upper = decode[channel * 2 + 1]
                        if lower == 0 && upper == 1 { return false }
                        if lower == 1 && upper == 0 { return true }
                        throw CLIPImagePreprocessingError.unsupportedPixelFormat
                    }
                } else {
                    cmykInverted = Array(repeating: false, count: 4)
                }
            } else {
                cmykInverted = nil
            }
            let pixelBytes = image.bitsPerPixel / 8
            let componentStart: Int
            let alpha: Int?
            switch image.alphaInfo {
            case .none:
                guard pixelBytes == colorCount else { throw CLIPImagePreprocessingError.unsupportedPixelFormat }
                componentStart = 0
                alpha = nil
            case .first, .premultipliedFirst, .noneSkipFirst:
                guard pixelBytes == colorCount + 1 else { throw CLIPImagePreprocessingError.unsupportedPixelFormat }
                componentStart = 1
                alpha = image.alphaInfo == .noneSkipFirst ? nil : 0
            case .last, .premultipliedLast, .noneSkipLast:
                guard pixelBytes == colorCount + 1 else { throw CLIPImagePreprocessingError.unsupportedPixelFormat }
                componentStart = 0
                alpha = image.alphaInfo == .noneSkipLast ? nil : colorCount
            default:
                throw CLIPImagePreprocessingError.unsupportedPixelFormat
            }
            guard image.bytesPerRow >= image.width * pixelBytes,
                  image.bytesPerRow <= maximumDecodedBytes / image.height else {
                throw CLIPImagePreprocessingError.imageTooLarge
            }
            let order = image.bitmapInfo.intersection(.byteOrderMask)
            let reversed = (pixelBytes == 4 && order == .byteOrder32Little)
                || (pixelBytes == 2 && order == .byteOrder16Little)
            func index(_ value: Int) -> Int { reversed ? pixelBytes - 1 - value : value }
            colorIndices = (0..<(isCMYK ? 4 : 3)).map { index(componentStart + (colorCount == 1 ? 0 : $0)) }
            alphaIndex = alpha.map(index)
            premultiplied = image.alphaInfo == .premultipliedFirst || image.alphaInfo == .premultipliedLast
            guard let bytes = image.dataProvider?.data,
                  CFDataGetLength(bytes) >= image.bytesPerRow * image.height else {
                throw CLIPImagePreprocessingError.invalidImage
            }
            data = bytes
            bytesPerRow = image.bytesPerRow
            bytesPerPixel = pixelBytes
        }
    }

    private struct Filter {
        let start: Int
        let weights: [Int]
        var end: Int { start + weights.count }
    }

    // Pillow 11.3 resampling conventions: bicubic a=-0.5, widened support for downsampling,
    // normalized 22-bit coefficients, and rounded/clamped 8-bit output after each axis.
    // Reference: https://github.com/python-pillow/Pillow/blob/11.3.0/src/libImaging/Resample.c
    private static func coefficients(input: Int, output: Int, start: Int) -> [Filter] {
        if input == output {
            return (start..<(start + imageSize)).map { Filter(start: $0, weights: [coefficientScale]) }
        }
        let scale = Double(input) / Double(output)
        let filterScale = max(1, scale)
        let radius = 2 * filterScale
        return (start..<(start + imageSize)).map { position in
            let center = (Double(position) + 0.5) * scale
            let lower = max(0, Int(center - radius + 0.5))
            let upper = min(input, Int(center + radius + 0.5))
            let weights = (lower..<upper).map { sample in
                bicubic(abs((Double(sample) + 0.5 - center) / filterScale))
            }
            let total = weights.reduce(0, +)
            return Filter(start: lower, weights: weights.map {
                Int(($0 / total * Double(coefficientScale)).rounded(.toNearestOrAwayFromZero))
            })
        }
    }

    private static func bicubic(_ x: Double) -> Double {
        if x < 1 { return 1 + x * x * (1.5 * x - 2.5) }
        if x < 2 { return 2 + x * (-4 + x * (2.5 - 0.5 * x)) }
        return 0
    }

    private static func roundedByte(_ value: Int) -> UInt8 {
        UInt8(clamping: value >> precision)
    }

    private static func sourcePoint(x: Int, y: Int, width: Int, height: Int,
                                    orientation: CGImagePropertyOrientation) -> (x: Int, y: Int) {
        switch orientation {
        case .up: (x, y)
        case .upMirrored: (width - 1 - x, y)
        case .down: (width - 1 - x, height - 1 - y)
        case .downMirrored: (x, height - 1 - y)
        case .leftMirrored: (y, x)
        case .right: (y, height - 1 - x)
        case .rightMirrored: (width - 1 - y, height - 1 - x)
        case .left: (width - 1 - y, x)
        @unknown default: (x, y)
        }
    }
}

// Pillow's copyright and MIT-CMU permission notice ship in Pillow-LICENSE.txt.
