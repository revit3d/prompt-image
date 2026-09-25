import Foundation
import Observation

/// Owns the demo's work so disappearing views cannot publish stale results or
/// overlap a cancelled Core ML prediction with a new indexing/search request.
@MainActor
@Observable
final class RetrievalDemoStore {
    enum Operation: Equatable { case loading, indexing, searching, closing }

    private(set) var summary: RetrievalDemoSummary?
    private(set) var operation: Operation?
    private(set) var isCancelling = false
    private(set) var isPrepared = false
    private(set) var completedImages = 0
    private(set) var totalImages = 0
    private(set) var result: RetrievalDemoSearchResult?
    private(set) var message: String?
    var isWorking: Bool { operation != nil }

    @ObservationIgnored private let engine: any RetrievalDemoServing
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var taskID = UUID()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var loadWhenIdle = false

    convenience init() { self.init(engine: RetrievalDemoEngine()) }

    init(engine: any RetrievalDemoServing) { self.engine = engine }

    deinit { task?.cancel() }

    func activate() {
        guard !isClosed else { return }
        isActive = true
        if summary == nil && message == nil { load() }
    }

    func load() {
        guard isActive, !isClosed else { return }
        guard !isWorking else {
            loadWhenIdle = summary == nil
            return
        }
        loadWhenIdle = false
        start(.loading) { store, generation in
            do {
                let summary = try await store.engine.load()
                guard store.accepts(generation) else { return }
                store.summary = summary
                store.totalImages = summary.imageCount
            } catch { store.record(error, generation: generation) }
        }
    }

    func prepare() {
        guard summary != nil, !isPrepared, canStart else { return }
        completedImages = 0
        totalImages = summary?.imageCount ?? 0
        result = nil
        start(.indexing) { store, generation in
            do {
                try await store.engine.prepare { [weak store] completed, total in
                    await store?.recordProgress(completed: completed, total: total, generation: generation)
                }
                guard store.accepts(generation) else { return }
                store.isPrepared = true
                store.completedImages = store.totalImages
            } catch { store.record(error, generation: generation) }
        }
    }

    func search(_ text: String, language: QueryLanguageChoice) {
        guard isPrepared, canStart else { return }
        result = nil
        start(.searching) { store, generation in
            do {
                let result = try await store.engine.search(text, language: language)
                guard store.accepts(generation) else { return }
                store.result = result
            } catch { store.record(error, generation: generation) }
        }
    }

    /// Editing affects pending query results, but does not interrupt indexing.
    func queryChanged() {
        result = nil
        if operation == .searching { cancel() }
        else if operation == nil { message = nil }
    }

    func cancel() {
        guard operation != .closing else { return }
        generation += 1
        task?.cancel()
        isCancelling = isWorking
        result = nil
        message = nil
        // A partially computed index is never usable. The engine also discards it.
        if operation == .indexing { isPrepared = false }
    }

    func deactivate() {
        isActive = false
        loadWhenIdle = false
        cancel()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        isActive = false
        loadWhenIdle = false
        cancel()
        let previous = task
        let id = UUID()
        taskID = id
        operation = .closing
        isPrepared = false
        task = Task { [self] in
            // Core ML has synchronous sections. Wait until the last operation
            // returns before unloading its resources, even if cancellation is slow.
            await previous?.value
            await engine.unload()
            finish(id)
        }
    }

    /// Also used by lifecycle tests to wait for actual cancellation completion.
    func waitForIdle() async {
        while let pending = task { await pending.value }
    }

    private var canStart: Bool { isActive && !isClosed && !isWorking }

    private func start(
        _ operation: Operation,
        work: @escaping @MainActor (RetrievalDemoStore, Int) async -> Void
    ) {
        generation += 1
        let generation = generation
        let id = UUID()
        taskID = id
        self.operation = operation
        isCancelling = false
        message = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.finish(id) }
            guard !Task.isCancelled else { return }
            await work(self, generation)
        }
    }

    private func finish(_ id: UUID) {
        guard id == taskID else { return }
        task = nil
        operation = nil
        isCancelling = false
        if loadWhenIdle && isActive && !isClosed {
            loadWhenIdle = false
            load()
        }
    }

    private func accepts(_ requestedGeneration: Int) -> Bool {
        generation == requestedGeneration && isActive && !isClosed && !Task.isCancelled
    }

    private func recordProgress(completed: Int, total: Int, generation: Int) {
        guard accepts(generation), operation == .indexing else { return }
        totalImages = max(0, total)
        completedImages = min(max(0, completed), totalImages)
    }

    private func record(_ error: any Error, generation: Int) {
        guard accepts(generation), !(error is CancellationError) else { return }
        switch error {
        case RetrievalDemoError.indexNotReady, RetrievalDemoError.imageChanged, RetrievalDemoError.invalidCorpus:
            isPrepared = false
            message = (error as? any LocalizedError)?.errorDescription
        case QueryInputError.empty:
            message = "Введите описание фотографии."
        case QueryInputError.tooLong, QueryTranslationError.inputTooLong:
            message = "Описание слишком длинное. Сократите его и попробуйте снова."
        case QueryInputError.ambiguousLanguage:
            message = "Не удалось уверенно определить язык. Выберите русский или английский."
        case QueryInputError.unsupportedLanguage, QueryTranslationError.unsupportedLanguagePair:
            message = "Пока поддерживаются русский и английский. Выберите язык вручную."
        case QueryTranslationError.modelUnavailable:
            message = "Модель перевода недоступна. Переустановите приложение или используйте английский язык."
        case QueryTranslationError.generationLimit, QueryTranslationError.inferenceFailed,
             QueryTranslationError.invalidTranslation:
            message = "Не удалось перевести описание. Попробуйте другую формулировку или английский язык."
        default:
            message = (error as? any LocalizedError)?.errorDescription
                ?? "Не удалось выполнить поиск. Попробуйте снова."
        }
    }
}
