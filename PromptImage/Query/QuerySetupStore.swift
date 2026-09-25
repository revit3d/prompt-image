import Foundation
import Observation

@MainActor
@Observable
final class QuerySetupStore {
    private(set) var availability: QueryTranslationAvailability?
    private(set) var isChecking = false
    private(set) var isProcessing = false
    private(set) var result: PreparedQuery?
    private(set) var queryMessage: String?

    @ObservationIgnored private let translator: any QueryTranslating
    @ObservationIgnored private let pipeline: QueryEmbeddingPipeline
    @ObservationIgnored private var queryGeneration = 0
    @ObservationIgnored private var availabilityGeneration = 0

    convenience init() { self.init(translator: BundledQueryTranslator()) }

    init(translator: any QueryTranslating, encoder: any QueryTextEncoding = LazyQueryTextEncoder()) {
        self.translator = translator
        pipeline = QueryEmbeddingPipeline(translator: translator, encoder: encoder)
    }

    func refreshAvailability() async {
        guard !Task.isCancelled else { return }
        availabilityGeneration += 1
        let generation = availabilityGeneration
        isChecking = true
        let current = await translator.availability()
        guard generation == availabilityGeneration else { return }
        isChecking = false
        guard !Task.isCancelled else { return }
        availability = current
    }

    func prepareQuery(_ text: String, language: QueryLanguageChoice) async {
        guard !Task.isCancelled else { return }
        clearQuery()
        let generation = queryGeneration
        isProcessing = true
        defer { if generation == queryGeneration { isProcessing = false } }
        do {
            let prepared = try await pipeline.prepare(text, language: language)
            guard generation == queryGeneration, !Task.isCancelled else { return }
            result = prepared
        } catch {
            guard generation == queryGeneration else { return }
            if !Task.isCancelled, !(error is CancellationError) {
                queryMessage = Self.message(for: error)
                if case QueryTranslationError.modelUnavailable = error {
                    availabilityGeneration += 1
                    isChecking = false
                    availability = .modelUnavailable
                }
            }
        }
    }

    func clearQuery() {
        queryGeneration += 1
        isProcessing = false
        result = nil
        queryMessage = nil
    }

    func deactivate() {
        clearQuery()
        availabilityGeneration += 1
        isChecking = false
    }

    func unload() async { await pipeline.unload() }

    private static func message(for error: Error) -> String {
        switch error {
        case QueryInputError.empty:
            return "Введите описание фотографии."
        case QueryInputError.tooLong, QueryTranslationError.inputTooLong:
            return "Описание слишком длинное. Сократите его и попробуйте снова."
        case QueryInputError.ambiguousLanguage:
            return "Не удалось уверенно определить язык. Выберите русский или английский."
        case QueryInputError.unsupportedLanguage, QueryTranslationError.unsupportedLanguagePair:
            return "Пока поддерживаются русский и английский. Если язык определён неверно, выберите его вручную."
        case QueryTranslationError.modelUnavailable:
            return "Модель перевода отсутствует или повреждена. Переустановите приложение. Английские описания доступны без перевода."
        case QueryTranslationError.generationLimit:
            return "Не удалось завершить перевод. Попробуйте более короткое и простое описание."
        case QueryTranslationError.inferenceFailed, QueryTranslationError.invalidTranslation:
            return "Не удалось перевести описание на iPhone. Попробуйте другую формулировку или английский язык."
        default:
            return "Не удалось подготовить описание. Попробуйте снова или сократите текст."
        }
    }
}
