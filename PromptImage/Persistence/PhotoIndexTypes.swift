import Foundation

/// Error messages deliberately omit SQL, asset identifiers, OCR text, and file paths.
nonisolated enum PhotoIndexError: Error, Equatable, LocalizedError {
    case storage(Int32)
    case invalidDatabase
    case unsupportedSchema(Int)
    case invalidInput
    case staleWork
    case closed
    case invalidTransition
    case invalidStoredData
    case fileProtection

    var errorDescription: String? {
        switch self {
        case .storage: "Не удалось сохранить или прочитать локальный индекс. Попробуйте снова."
        case .invalidDatabase: "Не удалось открыть локальный индекс."
        case .unsupportedSchema: "Эта версия локального индекса пока не поддерживается."
        case .invalidInput: "Не удалось сохранить результат обработки изображения."
        case .staleWork: "Изображение или настройки обработки изменились. Повторите обработку."
        case .closed: "Локальный индекс закрыт. Откройте его снова."
        case .invalidTransition: "Не удалось обновить состояние обработки изображения."
        case .invalidStoredData: "Сохранённый результат повреждён. Повторите обработку изображения."
        case .fileProtection: "Не удалось защитить локальный индекс."
        }
    }
}

nonisolated enum PhotoIndexStage: String, Sendable, CaseIterable {
    case embedding, ocr
}

nonisolated enum PhotoIndexStatus: String, Sendable {
    case pending, processing, complete, requiresDownload, failed
}

nonisolated enum PhotoIndexFailure: String, Sendable {
    case sourceUnavailable, invalidImage, tooLarge, unsupportedLanguages, modelUnavailable, processingFailed
}

nonisolated struct PhotoIndexVersions: Sendable, Equatable {
    let embedding: String
    let ocr: String
}

/// A completion may replace a result only while this generation, version, and attempt are current.
nonisolated struct PhotoIndexWork: Sendable, Equatable {
    let assetID: String
    let assetGeneration: UUID
    let stage: PhotoIndexStage
    let version: String
    let attemptID: UUID
}

nonisolated struct PhotoIndexStageState: Sendable, Equatable {
    let version: String
    let status: PhotoIndexStatus
    let failure: PhotoIndexFailure?
}

nonisolated struct PhotoIndexRecord: Sendable, Equatable {
    let photo: LibraryPhoto
    let generation: UUID
    let embedding: PhotoIndexStageState
    let ocr: PhotoIndexStageState
}

nonisolated struct PhotoIndexTextMatch: Sendable, Equatable {
    let assetID: String
    let text: String
    let rank: Double
}

nonisolated enum PhotoIndexPipeline {
    /// Bump pipeline-v1 when OCR decoding, recognition options, or line merging changes.
    /// Keep these constants in sync with PhotoOCREngine and PhotoOCRImage. Including
    /// the OS version also invalidates results when the system's Vision implementation changes.
    static var currentOCRVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "pipeline-v1;vision-r3;ru-RU,en-US;accurate;correction-on;auto-language-off;min-height-0;"
            + "short-edge-1600;decoded-pixels-24000000;tile-2048;overlap-256;"
            + "ios-\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}
