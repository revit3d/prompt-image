import CoreGraphics
import Foundation

nonisolated struct PhotoOCRLine: Sendable, Equatable {
    let text: String
    let confidence: Float
    /// Normalized coordinates in the upright image, with a bottom-left origin.
    let boundingBox: CGRect
}

nonisolated struct PhotoOCRResult: Sendable, Equatable {
    let lines: [PhotoOCRLine]
    let revision: Int
    let languages: [String]
    var text: String { lines.map(\.text).joined(separator: "\n") }
}

nonisolated protocol PhotoTextRecognizing: Sendable {
    func recognize(_ source: PhotoOCRSource) async throws -> PhotoOCRResult
}

nonisolated enum PhotoOCRError: Error, LocalizedError {
    case invalidImage, imageTooLarge, unsupportedLanguages, recognitionFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: "Не удалось прочитать изображение. Попробуйте другой снимок."
        case .imageTooLarge: "Изображение слишком большое для распознавания. Попробуйте уменьшенную копию."
        case .unsupportedLanguages: "Распознавание русского и английского недоступно на этой версии iOS."
        case .recognitionFailed: "Не удалось распознать текст. Попробуйте снова."
        }
    }
}
