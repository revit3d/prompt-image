import Foundation
import Observation

@MainActor
@Observable
final class PhotoAvailabilityScan {
    private(set) var results: [String: PhotoAvailability] = [:]
    private(set) var totalCount = 0
    private(set) var localCount = 0
    private(set) var downloadRequiredCount = 0
    private(set) var unavailableCount = 0
    private(set) var isRunning = false
    private(set) var hasStarted = false

    var checkedCount: Int { localCount + downloadRequiredCount + unavailableCount }
    var uncheckedCount: Int { totalCount - checkedCount }
    var skippedCount: Int { downloadRequiredCount + unavailableCount }

    @ObservationIgnored private let provider: any PhotoAvailabilityProviding
    @ObservationIgnored private var photos: [LibraryPhoto] = []
    @ObservationIgnored private var nextIndex = 0
    @ObservationIgnored private var wantsToRun = false
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var scheduledStep: Task<Void, Never>?
    @ObservationIgnored private var pendingToken: UUID?
    @ObservationIgnored private var pendingIndex: Int?
    @ObservationIgnored private var pendingRequest: UUID?

    convenience init() {
        self.init(provider: PhotoKitAvailabilityProvider())
    }

    init(provider: any PhotoAvailabilityProviding) {
        self.provider = provider
    }

    isolated deinit {
        scheduledStep?.cancel()
        if let pendingRequest { provider.cancel(pendingRequest) }
    }

    func updatePhotos(_ newPhotos: [LibraryPhoto]) {
        let previous = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        let incoming = Dictionary(uniqueKeysWithValues: newPhotos.map { ($0.id, $0) })
        // A refresh or a new display order alone must not interrupt a probe.
        guard previous != incoming else { return }

        cancelPending()
        results = results.filter { id, _ in
            guard let oldPhoto = previous[id], let newPhoto = incoming[id] else { return false }
            return oldPhoto == newPhoto
        }
        photos = newPhotos
        totalCount = newPhotos.count
        nextIndex = 0
        recountResults()
        scheduleNext()
    }

    func start() {
        hasStarted = true
        wantsToRun = true
        scheduleNext()
    }

    func pause() {
        wantsToRun = false
        cancelPending()
    }

    func restart() {
        cancelPending()
        results = [:]
        localCount = 0
        downloadRequiredCount = 0
        unavailableCount = 0
        nextIndex = 0
        start()
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            scheduleNext()
        } else {
            cancelPending()
        }
    }

    func clear() {
        wantsToRun = false
        cancelPending()
        photos = []
        results = [:]
        totalCount = 0
        localCount = 0
        downloadRequiredCount = 0
        unavailableCount = 0
        nextIndex = 0
        hasStarted = false
    }

    private func recountResults() {
        localCount = 0
        downloadRequiredCount = 0
        unavailableCount = 0
        for result in results.values { incrementCount(for: result) }
    }

    private func incrementCount(for result: PhotoAvailability) {
        switch result {
        case .local: localCount += 1
        case .requiresDownload: downloadRequiredCount += 1
        case .unavailable: unavailableCount += 1
        }
    }

    private func cancelPending() {
        generation += 1
        scheduledStep?.cancel()
        scheduledStep = nil
        if let pendingIndex { nextIndex = min(nextIndex, pendingIndex) }
        let request = pendingRequest
        pendingToken = nil
        pendingIndex = nil
        pendingRequest = nil
        isRunning = false
        // Settle our state before cancellation; providers need not call back.
        if let request { provider.cancel(request) }
    }

    private func scheduleNext() {
        guard wantsToRun, isActive, pendingToken == nil, scheduledStep == nil else { return }
        while nextIndex < photos.count, results[photos[nextIndex].id] != nil {
            nextIndex += 1
        }
        guard nextIndex < photos.count else {
            isRunning = false
            return
        }

        isRunning = true
        let requestGeneration = generation
        // Each probe gets a separate task, even with a synchronous provider.
        scheduledStep = Task { [weak self] in
            guard !Task.isCancelled, let self, self.generation == requestGeneration else { return }
            self.scheduledStep = nil
            self.beginNext(generation: requestGeneration)
        }
    }

    private func beginNext(generation requestGeneration: Int) {
        guard wantsToRun, isActive, generation == requestGeneration, nextIndex < photos.count else { return }
        let photo = photos[nextIndex]
        let token = UUID()
        pendingToken = token
        pendingIndex = nextIndex
        nextIndex += 1
        let request = provider.checkAvailability(of: photo) { [weak self] result in
            // Queue completion so the request ID is registered before it runs.
            Task { @MainActor [weak self] in
                self?.didCheck(photo, result: result, token: token, generation: requestGeneration)
            }
        }
        if pendingToken == token, generation == requestGeneration {
            pendingRequest = request
        } else {
            provider.cancel(request)
        }
    }

    private func didCheck(
        _ photo: LibraryPhoto,
        result: PhotoAvailability,
        token: UUID,
        generation requestGeneration: Int
    ) {
        guard generation == requestGeneration, pendingToken == token else { return }
        pendingToken = nil
        pendingIndex = nil
        pendingRequest = nil
        results[photo.id] = result
        incrementCount(for: result)
        scheduleNext()
    }
}
