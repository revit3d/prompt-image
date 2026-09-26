import Foundation
import Observation

nonisolated enum PhotoSearchPhase: Equatable {
    case idle, waitingForIndex, emptyIndex, searching, results, noMatches, failed
}

/// Keeps one query/unload operation alive until native work actually returns.
/// A submitted replacement waits for that operation; edits invalidate immediately.
@MainActor
@Observable
final class PhotoSearchStore {
    var text = "" { didSet { if text != oldValue { queryChanged() } } }
    var language = QueryLanguageChoice.automatic {
        didSet { if language != oldValue { queryChanged() } }
    }
    var mode = PhotoSearchMode.combined {
        didSet {
            if mode != oldValue {
                queryChanged()
                requestUnload()
            }
        }
    }
    private(set) var phase: PhotoSearchPhase = .idle
    private(set) var matches: [PhotoSearchMatch] = []
    private(set) var message: String?
    private(set) var isWorking = false
    private(set) var selectedPhoto: LibraryPhoto?

    @ObservationIgnored private let engine: any PhotoSearchServing
    @ObservationIgnored private let indexState: @MainActor () -> PhotoSearchIndexState
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pending: Request?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var needsUnload = false
    @ObservationIgnored private var hasUsedEngine = false

    init(engine: any PhotoSearchServing, indexState: @escaping @MainActor () -> PhotoSearchIndexState) {
        self.engine = engine
        self.indexState = indexState
    }

    isolated deinit { worker?.cancel() }

    var currentIndex: PhotoSearchIndexState { indexState() }

    func activate() { isActive = true }

    func deactivate() {
        isActive = false
        reset()
        requestUnload()
    }

    func invalidateLibrary() {
        reset()
        if isActive { phase = .waitingForIndex }
        requestUnload()
    }

    func search() {
        guard isActive else { return }
        reset()
        do { try PhotoSearchPipeline.validate(text, limit: 50) }
        catch {
            phase = .failed
            message = Self.message(for: error)
            return
        }
        guard checkIndex(for: mode) else { return }
        pending = Request(generation: generation, text: text, language: language, mode: mode)
        phase = .searching
        kick()
    }

    func cancel() { reset() }

    func select(_ photo: LibraryPhoto) {
        guard isActive, indexState().isReady, phase == .results,
              matches.contains(where: { $0.photo == photo }) else { return }
        selectedPhoto = photo
    }

    func dismissPhoto() { selectedPhoto = nil }

    func waitForIdle() async {
        while let worker { await worker.value }
    }

    private func queryChanged() { reset() }

    private func checkIndex(for mode: PhotoSearchMode) -> Bool {
        let state = indexState()
        guard state.isReady else {
            phase = .waitingForIndex
            return false
        }
        let available = mode == .textOnly ? state.summary.ocrCount
            : state.summary.embeddingCount + state.summary.ocrCount
        guard available > 0 else {
            phase = .emptyIndex
            return false
        }
        return true
    }

    private func reset() {
        generation += 1
        worker?.cancel()
        pending = nil
        matches = []
        selectedPhoto = nil
        message = nil
        phase = .idle
    }

    private func requestUnload() {
        needsUnload = hasUsedEngine
        kick()
    }

    private func kick() {
        guard worker == nil, needsUnload || (isActive && pending != nil) else { return }
        isWorking = true
        worker = Task { [weak self] in
            guard let self else { return }
            // Unloading can suspend. A newly submitted query must wait for it too.
            await self.unloadIfNeeded()
            if !Task.isCancelled, self.isActive, let request = self.pending,
               self.checkIndex(for: request.mode) {
                self.pending = nil
                self.hasUsedEngine = true
                do {
                    let results = try await self.engine.search(request.text, language: request.language,
                        mode: request.mode, limit: 50)
                    if self.accepts(request) {
                        if self.indexState().isReady {
                            self.matches = results
                            self.phase = results.isEmpty ? .noMatches : .results
                        } else {
                            self.phase = .waitingForIndex
                        }
                    }
                } catch {
                    if self.accepts(request) {
                        if error is CancellationError {
                            self.phase = .idle
                        } else if error as? PhotoSearchError == .indexNotReady {
                            self.phase = .waitingForIndex
                        } else {
                            self.phase = .failed
                            self.message = Self.message(for: error)
                        }
                    }
                }
            }
            // A queued request may have lost its ready index while older work drained.
            if self.phase == .waitingForIndex || self.phase == .emptyIndex { self.pending = nil }
            await self.unloadIfNeeded()
            self.worker = nil
            self.isWorking = false
            self.kick()
        }
    }

    private func unloadIfNeeded() async {
        while needsUnload {
            needsUnload = false
            await engine.unload()
            hasUsedEngine = false
        }
    }

    private func accepts(_ request: Request) -> Bool {
        isActive && generation == request.generation && !Task.isCancelled
    }

    private struct Request {
        let generation: Int
        let text: String
        let language: QueryLanguageChoice
        let mode: PhotoSearchMode
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case QueryInputError.empty:
            "Введите описание или слова, которые нужно найти."
        case QueryInputError.tooLong, QueryTranslationError.inputTooLong:
            "Запрос слишком длинный. Используйте не больше 32 слов и сократите описание."
        case QueryInputError.ambiguousLanguage:
            "Не удалось определить язык. Выберите русский или английский вручную."
        case QueryInputError.unsupportedLanguage, QueryTranslationError.unsupportedLanguagePair:
            "Для поиска по описанию выберите русский или английский. Для слов внутри изображения используйте «Текст на фото»."
        case QueryTranslationError.modelUnavailable:
            "Перевод недоступен. Попробуйте запрос на английском или режим «Текст на фото»."
        case QueryTranslationError.generationLimit, QueryTranslationError.inferenceFailed,
             QueryTranslationError.invalidTranslation:
            "Не удалось перевести описание. Измените формулировку, используйте английский или режим «Текст на фото»."
        case CLIPEmbeddingError.incompatibleModels:
            "Индекс создан другой версией модели. Перестройте индекс на экране фотографий."
        case is CLIPModelResourceError:
            "Модель поиска недоступна. Попробуйте режим «Текст на фото» или переустановите приложение."
        case is PhotoIndexError:
            "Локальный индекс недоступен. Разблокируйте iPhone и попробуйте снова."
        default:
            "Не удалось выполнить поиск. Попробуйте снова."
        }
    }
}
