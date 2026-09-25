import Foundation
import Observation

/// Keeps recognized text only for the current viewer session. Cancellation
/// invalidates results immediately, but keeps Vision busy until its work returns.
@MainActor
@Observable
final class PhotoOCRStore {
    enum Operation: Equatable { case loading, recognizing }
    enum SourceFailure: Equatable { case requiresDownload, unavailable }

    private(set) var operation: Operation?
    private(set) var isCancelling = false
    private(set) var result: PhotoOCRResult?
    private(set) var sourceFailure: SourceFailure?
    private(set) var message: String?
    var isWorking: Bool { operation != nil }

    @ObservationIgnored private let provider: any PhotoOCRSourceProviding
    @ObservationIgnored private let engine: any PhotoTextRecognizing
    @ObservationIgnored private var photo: LibraryPhoto?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var sourceIsPending = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var taskID = UUID()

    convenience init() {
        self.init(provider: PhotoKitOCRSourceProvider(), engine: PhotoOCREngine.shared)
    }

    init(provider: any PhotoOCRSourceProviding, engine: any PhotoTextRecognizing) {
        self.provider = provider
        self.engine = engine
    }

    deinit { task?.cancel() }

    func activate(for photo: LibraryPhoto) {
        if self.photo != photo {
            cancel()
            self.photo = photo
        }
        isActive = true
    }

    func start() {
        guard isActive, !isWorking, let photo else { return }
        generation += 1
        let generation = generation
        result = nil
        sourceFailure = nil
        message = nil
        isCancelling = false
        operation = .loading
        sourceIsPending = true
        let identifier = provider.requestSource(for: photo) { [weak self] source in
            self?.receive(source, generation: generation)
        }
        // A local provider can finish before returning its request identifier.
        if sourceIsPending, self.generation == generation {
            requestID = identifier
        }
    }

    func cancel() {
        generation += 1
        sourceIsPending = false
        let cancelledRequest = requestID
        requestID = nil
        result = nil
        sourceFailure = nil
        message = nil
        task?.cancel()
        isCancelling = task != nil
        if task == nil { operation = nil }
        if let cancelledRequest { provider.cancel(cancelledRequest) }
    }

    func deactivate() {
        isActive = false
        cancel()
    }

    /// Waits for an already submitted recognition to actually finish.
    func waitForIdle() async {
        while let pending = task { await pending.value }
    }

    private func receive(_ source: PhotoOCRSourceResult, generation: Int) {
        guard accepts(generation), sourceIsPending else { return }
        sourceIsPending = false
        requestID = nil
        switch source {
        case .requiresDownload:
            sourceFailure = .requiresDownload
            operation = nil
        case .unavailable:
            sourceFailure = .unavailable
            operation = nil
        case .source(let source):
            operation = .recognizing
            let id = UUID()
            taskID = id
            task = Task { [weak self] in
                guard let self else { return }
                defer { self.finish(id) }
                guard !Task.isCancelled else { return }
                do {
                    let result = try await engine.recognize(source)
                    guard self.accepts(generation), !Task.isCancelled else { return }
                    self.result = result
                } catch {
                    guard self.accepts(generation), !Task.isCancelled,
                          !(error is CancellationError) else { return }
                    self.message = (error as? PhotoOCRError)?.errorDescription
                        ?? "Не удалось распознать текст. Попробуйте снова."
                }
            }
        }
    }

    private func accepts(_ requestedGeneration: Int) -> Bool {
        generation == requestedGeneration && isActive
    }

    private func finish(_ id: UUID) {
        guard taskID == id else { return }
        task = nil
        operation = nil
        isCancelling = false
    }
}
