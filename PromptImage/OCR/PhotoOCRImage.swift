import CoreImage
import Foundation
import ImageIO

/// Separate from CLIP's 224px center crop: keep the whole image and useful text resolution.
nonisolated enum PhotoOCRImage {
    static let maximumEncodedBytes = PhotoOCRSource.maximumEncodedBytes
    static let maximumSourcePixels = 100_000_000
    static let maximumDecodedPixels = 24_000_000
    static let maximumDimension = 65_536
    static let shortEdge = 1_600
    static let tileEdge = 2_048
    static let overlap = 256

    struct Tile: Sendable {
        let region: CGRect

        func map(_ box: CGRect, imageSize: CGSize) -> CGRect {
            CGRect(x: (region.minX + box.minX * region.width) / imageSize.width,
                   y: (region.minY + box.minY * region.height) / imageSize.height,
                   width: box.width * region.width / imageSize.width,
                   height: box.height * region.height / imageSize.height)
        }

        /// A detection near an internal crop edge may contain only part of a line.
        /// Outer image edges have no neighboring tile with more context.
        func isInterior(_ box: CGRect, imageSize: CGSize) -> Bool {
            let margin: CGFloat = 8
            return (region.minX == 0 || box.minX * region.width >= margin)
                && (region.minY == 0 || box.minY * region.height >= margin)
                && (region.maxX == imageSize.width || (1 - box.maxX) * region.width >= margin)
                && (region.maxY == imageSize.height || (1 - box.maxY) * region.height >= margin)
        }
    }

    static func decode(_ source: PhotoOCRSource) throws -> CIImage {
        try Task.checkCancellation()
        guard !source.data.isEmpty else { throw PhotoOCRError.invalidImage }
        guard source.data.count <= maximumEncodedBytes else { throw PhotoOCRError.imageTooLarge }
        guard let imageSource = CGImageSourceCreateWithData(source.data as CFData,
                                                          [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw PhotoOCRError.invalidImage
        }
        let edge = try thumbnailEdge(width: width, height: height)
        // Ignore embedded orientation here; apply PhotoKit's authoritative orientation once below.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw PhotoOCRError.invalidImage
        }
        guard image.width > 0, image.height > 0,
              image.width <= maximumDimension, image.height <= maximumDimension,
              image.width <= maximumDecodedPixels / image.height else { throw PhotoOCRError.imageTooLarge }
        try Task.checkCancellation()
        let oriented = CIImage(cgImage: image).oriented(source.orientation)
        let upright = oriented.transformed(by: .init(translationX: -oriented.extent.minX,
                                                     y: -oriented.extent.minY))
        // Flatten transparency against white so transparent screenshots stay readable.
        return upright.composited(over: CIImage(color: .white).cropped(to: upright.extent))
    }

    static func thumbnailEdge(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0 else { throw PhotoOCRError.invalidImage }
        guard width <= maximumDimension, height <= maximumDimension,
              width <= maximumSourcePixels / height else { throw PhotoOCRError.imageTooLarge }
        let scale = min(1, Double(shortEdge) / Double(min(width, height)),
                        sqrt(Double(maximumDecodedPixels) / (Double(width) * Double(height))))
        return max(1, Int((Double(max(width, height)) * scale).rounded(.down)))
    }

    static func tiles(width: Int, height: Int) -> [Tile] {
        func spans(_ length: Int) -> [(start: Int, end: Int)] {
            guard length > tileEdge else { return [(0, length)] }
            var starts = [0]
            while starts.last! + tileEdge < length { starts.append(starts.last! + tileEdge - overlap) }
            return starts.map { ($0, min(length, $0 + tileEdge)) }
        }
        return spans(height).reversed().flatMap { y in
            spans(width).map { x in
                Tile(region: CGRect(x: x.start, y: y.start, width: x.end - x.start, height: y.end - y.start))
            }
        }
    }
}
