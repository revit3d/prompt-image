import CoreImage
import Foundation
import Vision

/// Serial off-main-actor decoding and OCR. Results and image data are never written or logged.
actor PhotoOCREngine: PhotoTextRecognizing {
    /// Share the serial executor across viewer replacements, including slow cancellation.
    static let shared = PhotoOCREngine()
    static let revision = VNRecognizeTextRequestRevision3
    static let languages = ["ru-RU", "en-US"]

    func recognize(_ source: PhotoOCRSource) async throws -> PhotoOCRResult {
        try Task.checkCancellation()
        let cancellation = OCRRequestCancellation()
        return try await withTaskCancellationHandler {
            try autoreleasepool {
                let request = try Self.makeRequest()
                cancellation.install(request)
                defer { cancellation.clear() }
                try Task.checkCancellation()
                let image = try PhotoOCRImage.decode(source)
                let context = CIContext(options: [.cacheIntermediates: false])
                defer { context.clearCaches() }
                let size = image.extent.size
                var detections: [PhotoOCRLineMerger.Detection] = []
                for (tileIndex, tile) in PhotoOCRImage.tiles(width: Int(size.width), height: Int(size.height)).enumerated() {
                    try Task.checkCancellation()
                    try autoreleasepool {
                        guard let pixels = context.createCGImage(image, from: tile.region, format: .RGBA8,
                                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
                            throw PhotoOCRError.invalidImage
                        }
                        do {
                            try VNImageRequestHandler(cgImage: pixels, orientation: .up).perform([request])
                        } catch {
                            try Task.checkCancellation()
                            throw PhotoOCRError.recognitionFailed
                        }
                        try Task.checkCancellation()
                        for observation in request.results ?? [] {
                            guard let candidate = observation.topCandidates(1).first else { continue }
                            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            let line = PhotoOCRLine(text: text, confidence: candidate.confidence,
                                                    boundingBox: tile.map(observation.boundingBox, imageSize: size))
                            detections.append(PhotoOCRLineMerger.Detection(
                                line: line, tileIndex: tileIndex,
                                isInterior: tile.isInterior(observation.boundingBox, imageSize: size)
                            ))
                        }
                    }
                }
                let lines = PhotoOCRLineMerger.merge(detections)
                try Task.checkCancellation()
                return PhotoOCRResult(lines: lines, revision: Self.revision, languages: Self.languages)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func makeRequest() throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.revision = revision
        request.recognitionLevel = .accurate
        let supported: [String]
        do { supported = try request.supportedRecognitionLanguages() }
        catch { throw PhotoOCRError.unsupportedLanguages }
        guard languages.allSatisfy(supported.contains) else { throw PhotoOCRError.unsupportedLanguages }
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = false
        request.minimumTextHeight = 0
        return request
    }
}

/// VNRequest.cancel() may run concurrently with perform(). The lock protects registration,
/// including cancellation before Vision starts; it never encloses perform().
private nonisolated final class OCRRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var isCancelled = false

    func install(_ request: VNRequest) {
        lock.lock()
        self.request = request
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { request.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let request = request
        lock.unlock()
        request?.cancel()
    }

    func clear() {
        lock.lock()
        request = nil
        lock.unlock()
    }
}
