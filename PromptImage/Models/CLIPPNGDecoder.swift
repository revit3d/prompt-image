import Foundation
import zlib

/// ImageIO on iOS exposes premultiplied PNG pixels, losing invisible RGB values and
/// quantizing translucent colors. Decode explicit 8-bit alpha PNGs without that loss.
/// Other image formats remain ImageIO's responsibility. This uses the public system
/// zlib codec and PNG's five row filters; the whole inflated stream is never buffered.
nonisolated struct CLIPPNGDecoder {
    struct Image {
        let width: Int
        let height: Int
        let channels: Int
        let pixels: Data
    }

    static func decodeAlphaPNG(_ data: Data) throws -> Image? {
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return nil }
        guard data.count <= CLIPImagePreprocessor.maximumEncodedBytes else {
            throw CLIPImagePreprocessingError.imageTooLarge
        }
        return try data.withUnsafeBytes { raw -> Image? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { throw CLIPImagePreprocessingError.invalidImage }
            var position = 8
            var dimensions: (width: Int, height: Int)?
            var color = 0
            var depth = 0
            var interlaced = false
            var idat: [Range<Int>] = []
            var idatFinished = false
            var ended = false
            var hasTransparency = false
            while position < data.count {
                try Task.checkCancellation()
                guard data.count - position >= 12 else { throw CLIPImagePreprocessingError.invalidImage }
                let length = integer(bytes, at: position)
                guard length <= data.count - position - 12 else { throw CLIPImagePreprocessingError.invalidImage }
                let payload = (position + 8)..<(position + 8 + length)
                let type = integer(bytes, at: position + 4)
                let expectedCRC = integer(bytes, at: payload.upperBound)
                let actualCRC = crc32(0, base + position + 4, uInt(length + 4))
                guard UInt32(actualCRC) == UInt32(expectedCRC) else {
                    throw CLIPImagePreprocessingError.invalidImage
                }
                if type != 0x49484452 && dimensions == nil { throw CLIPImagePreprocessingError.invalidImage }
                if !idat.isEmpty && type != 0x49444154 { idatFinished = true }
                switch type {
                case 0x49484452: // IHDR
                    guard dimensions == nil, position == 8, length == 13 else {
                        throw CLIPImagePreprocessingError.invalidImage
                    }
                    let width = integer(bytes, at: payload.lowerBound)
                    let height = integer(bytes, at: payload.lowerBound + 4)
                    _ = try CLIPImagePreprocessor.resizeGeometry(width: width, height: height)
                    dimensions = (width, height)
                    depth = Int(bytes[payload.lowerBound + 8])
                    color = Int(bytes[payload.lowerBound + 9])
                    guard bytes[payload.lowerBound + 10] == 0, bytes[payload.lowerBound + 11] == 0,
                          bytes[payload.lowerBound + 12] <= 1 else {
                        throw CLIPImagePreprocessingError.unsupportedPixelFormat
                    }
                    interlaced = bytes[payload.lowerBound + 12] == 1
                case 0x49444154: // IDAT
                    guard !idatFinished else { throw CLIPImagePreprocessingError.invalidImage }
                    if !payload.isEmpty { idat.append(payload) }
                case 0x49454E44: // IEND
                    guard length == 0, !idat.isEmpty else { throw CLIPImagePreprocessingError.invalidImage }
                    ended = true
                case 0x504C5445: // PLTE
                    guard idat.isEmpty, length > 0, length <= 768, length.isMultiple(of: 3) else {
                        throw CLIPImagePreprocessingError.invalidImage
                    }
                case 0x74524E53: // tRNS: palette/color-key transparency needs separate expansion.
                    hasTransparency = true
                default:
                    guard bytes[position + 4] & 0x20 != 0 else {
                        throw CLIPImagePreprocessingError.unsupportedPixelFormat
                    }
                }
                position = payload.upperBound + 4
                if ended { break }
            }
            guard ended, position == data.count, let dimensions else {
                throw CLIPImagePreprocessingError.invalidImage
            }
            if hasTransparency { throw CLIPImagePreprocessingError.unsupportedPixelFormat }
            guard color == 4 || color == 6 else { return nil }
            guard depth == 8 else { throw CLIPImagePreprocessingError.unsupportedPixelFormat }
            let channels = color == 6 ? 4 : 2
            let rowBytes = dimensions.width * channels
            guard rowBytes <= CLIPImagePreprocessor.maximumDecodedBytes / dimensions.height else {
                throw CLIPImagePreprocessingError.imageTooLarge
            }
            var output = Data(count: rowBytes * dimensions.height)
            try output.withUnsafeMutableBytes { outputRaw in
                let destination = outputRaw.bindMemory(to: UInt8.self)
                let inflater = try Inflater(base: base, chunks: idat)
                // Adam7: x/y origin and x/y sample spacing. Noninterlaced is one pass.
                let passes = interlaced
                    ? [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
                       (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
                    : [(0, 0, 1, 1)]
                for (startX, startY, stepX, stepY) in passes {
                    guard startX < dimensions.width, startY < dimensions.height else { continue }
                    let passWidth = (dimensions.width - startX + stepX - 1) / stepX
                    let passHeight = (dimensions.height - startY + stepY - 1) / stepY
                    var previous = [UInt8](repeating: 0, count: passWidth * channels)
                    var scanline = [UInt8](repeating: 0, count: passWidth * channels + 1)
                    for row in 0..<passHeight {
                        try Task.checkCancellation()
                        try inflater.read(into: &scanline)
                        let filter = scanline[0]
                        guard filter <= 4 else { throw CLIPImagePreprocessingError.invalidImage }
                        for byte in 0..<previous.count {
                            let left = byte >= channels ? scanline[byte + 1 - channels] : 0
                            let above = previous[byte]
                            let upperLeft = byte >= channels ? previous[byte - channels] : 0
                            let predictor: UInt8
                            switch filter {
                            case 0: predictor = 0
                            case 1: predictor = left
                            case 2: predictor = above
                            case 3: predictor = UInt8((Int(left) + Int(above)) / 2)
                            default: predictor = paeth(left, above, upperLeft)
                            }
                            scanline[byte + 1] &+= predictor
                        }
                        for column in 0..<passWidth {
                            let offset = (startY + row * stepY) * rowBytes + (startX + column * stepX) * channels
                            for channel in 0..<channels {
                                destination[offset + channel] = scanline[1 + column * channels + channel]
                            }
                        }
                        for byte in previous.indices { previous[byte] = scanline[byte + 1] }
                    }
                }
                try inflater.finish()
            }
            return Image(width: dimensions.width, height: dimensions.height, channels: channels, pixels: output)
        }
    }

    private static func integer(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Int {
        Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }

    private static func paeth(_ left: UInt8, _ above: UInt8, _ upperLeft: UInt8) -> UInt8 {
        let prediction = Int(left) + Int(above) - Int(upperLeft)
        let leftDistance = abs(prediction - Int(left))
        let aboveDistance = abs(prediction - Int(above))
        let diagonalDistance = abs(prediction - Int(upperLeft))
        if leftDistance <= aboveDistance && leftDistance <= diagonalDistance { return left }
        return aboveDistance <= diagonalDistance ? above : upperLeft
    }

    private final class Inflater {
        private let stream: UnsafeMutablePointer<z_stream>
        private let base: UnsafePointer<UInt8>
        private let chunks: [Range<Int>]
        private var chunkIndex = 0
        private var ended = false

        init(base: UnsafePointer<UInt8>, chunks: [Range<Int>]) throws {
            self.base = base
            self.chunks = chunks
            let state = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
            state.initialize(to: z_stream())
            guard inflateInit_(state, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                state.deinitialize(count: 1)
                state.deallocate()
                throw CLIPImagePreprocessingError.invalidImage
            }
            stream = state
        }

        deinit {
            inflateEnd(stream)
            stream.deinitialize(count: 1)
            stream.deallocate()
        }

        func read(into bytes: inout [UInt8]) throws {
            guard !ended else { throw CLIPImagePreprocessingError.invalidImage }
            try bytes.withUnsafeMutableBytes { raw in
                stream.pointee.next_out = raw.bindMemory(to: UInt8.self).baseAddress
                stream.pointee.avail_out = uInt(raw.count)
                while stream.pointee.avail_out > 0 {
                    try provideInput()
                    let status = inflate(stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END else {
                        throw CLIPImagePreprocessingError.invalidImage
                    }
                    if status == Z_STREAM_END {
                        ended = true
                        guard stream.pointee.avail_out == 0 else { throw CLIPImagePreprocessingError.invalidImage }
                        break
                    }
                }
            }
        }

        func finish() throws {
            // A full-sized image followed by extra inflated bytes is invalid, even when
            // the input advertises small dimensions. One byte detects such zip bombs.
            var extra: UInt8 = 0
            try withUnsafeMutablePointer(to: &extra) { pointer in
                stream.pointee.next_out = pointer
                stream.pointee.avail_out = 1
                while !ended {
                    try provideInput()
                    let status = inflate(stream, Z_NO_FLUSH)
                    guard stream.pointee.avail_out == 1, status == Z_OK || status == Z_STREAM_END else {
                        throw CLIPImagePreprocessingError.invalidImage
                    }
                    ended = status == Z_STREAM_END
                }
            }
            guard stream.pointee.avail_in == 0, chunkIndex == chunks.count else {
                throw CLIPImagePreprocessingError.invalidImage
            }
        }

        private func provideInput() throws {
            guard stream.pointee.avail_in == 0 else { return }
            guard chunkIndex < chunks.count else { throw CLIPImagePreprocessingError.invalidImage }
            let chunk = chunks[chunkIndex]
            stream.pointee.next_in = UnsafeMutablePointer(mutating: base + chunk.lowerBound)
            stream.pointee.avail_in = uInt(chunk.count)
            chunkIndex += 1
        }
    }
}
