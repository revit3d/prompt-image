import CoreGraphics
import Foundation

/// Explicit storage formats keep persistence independent of the model and OCR value types.
nonisolated enum PhotoIndexCodec {
    static let embeddingDimensions = 512
    static let maximumOCRBytes = 4 * 1_024 * 1_024
    private static let maximumOCRLines = 20_000
    private static let maximumLineBytes = 64 * 1_024
    private static let ocrFormatVersion = 1

    static func encodeEmbedding(_ embedding: CLIPEmbedding) throws -> Data {
        try validateEmbedding(embedding.values, modelID: embedding.modelID, error: .invalidInput)
        var data = Data()
        data.reserveCapacity(embeddingDimensions * MemoryLayout<Float>.size)
        for value in embedding.values {
            let bits = value.bitPattern
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
            data.append(UInt8(truncatingIfNeeded: bits >> 16))
            data.append(UInt8(truncatingIfNeeded: bits >> 24))
        }
        return data
    }

    static func decodeEmbedding(_ data: Data, modelID: String) throws -> CLIPEmbedding {
        guard data.count == embeddingDimensions * 4 else { throw PhotoIndexError.invalidStoredData }
        // Read individual bytes rather than an aligned Float pointer: SQLite BLOBs and
        // Data slices need not share the host's alignment or native byte order.
        let bytes = [UInt8](data)
        var values = [Float]()
        values.reserveCapacity(embeddingDimensions)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let bits = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
            values.append(Float(bitPattern: bits))
        }
        try validateEmbedding(values, modelID: modelID, error: .invalidStoredData)
        // The constructor accounts for normal Float32 rounding only after the stored
        // norm has passed validation. It must never repair a corrupt vector's scale.
        return try CLIPEmbedding(rawValues: values, modelID: modelID)
    }

    static func encodeOCR(_ result: PhotoOCRResult) throws -> Data {
        try validateOCR(result, error: .invalidInput)
        let envelope = OCREnvelope(formatVersion: ocrFormatVersion, revision: result.revision,
                                   languages: result.languages, lines: result.lines.map(OCRLine.init))
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(envelope)
        } catch {
            throw PhotoIndexError.invalidInput
        }
        guard data.count <= maximumOCRBytes else { throw PhotoIndexError.invalidInput }
        return data
    }

    static func decodeOCR(_ data: Data) throws -> PhotoOCRResult {
        guard !data.isEmpty, data.count <= maximumOCRBytes else { throw PhotoIndexError.invalidStoredData }
        let envelope: OCREnvelope
        do { envelope = try JSONDecoder().decode(OCREnvelope.self, from: data) }
        catch { throw PhotoIndexError.invalidStoredData }
        guard envelope.formatVersion == ocrFormatVersion else { throw PhotoIndexError.invalidStoredData }
        let result = PhotoOCRResult(lines: envelope.lines.map(\.result), revision: envelope.revision,
                                    languages: envelope.languages)
        try validateOCR(result, error: .invalidStoredData)
        return result
    }

    private static func validateEmbedding(_ values: [Float], modelID: String, error: PhotoIndexError) throws {
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              modelID.utf8.count <= 1_024, values.count == embeddingDimensions,
              values.allSatisfy(\.isFinite) else { throw error }
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, abs(norm - 1) <= 0.000_01 else { throw error }
    }

    private static func validateOCR(_ result: PhotoOCRResult, error: PhotoIndexError) throws {
        guard (1...3).contains(result.revision), !result.languages.isEmpty,
              result.languages.count <= 16, Set(result.languages).count == result.languages.count,
              result.languages.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.utf8.count <= 64 }),
              result.lines.count <= maximumOCRLines else { throw error }
        var totalTextBytes = 0
        for line in result.lines {
            let textBytes = line.text.utf8.count
            guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  textBytes <= maximumLineBytes else { throw error }
            totalTextBytes += textBytes
            guard totalTextBytes <= maximumOCRBytes, line.confidence.isFinite,
                  (0...1).contains(line.confidence) else { throw error }
            let box = line.boundingBox
            let components = [box.origin.x, box.origin.y, box.size.width, box.size.height]
            guard components.allSatisfy(\.isFinite), box.origin.x >= 0, box.origin.y >= 0,
                  box.size.width > 0, box.size.height > 0,
                  box.origin.x + box.size.width <= 1.000_001,
                  box.origin.y + box.size.height <= 1.000_001 else { throw error }
        }
    }

    private struct OCREnvelope: Codable {
        let formatVersion: Int
        let revision: Int
        let languages: [String]
        let lines: [OCRLine]
    }

    private struct OCRLine: Codable {
        let text: String
        let confidence: Float
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ line: PhotoOCRLine) {
            text = line.text
            confidence = line.confidence
            x = Double(line.boundingBox.origin.x)
            y = Double(line.boundingBox.origin.y)
            width = Double(line.boundingBox.size.width)
            height = Double(line.boundingBox.size.height)
        }

        var result: PhotoOCRLine {
            PhotoOCRLine(text: text, confidence: confidence,
                         boundingBox: CGRect(x: x, y: y, width: width, height: height))
        }
    }
}
