import Foundation
import Observation

nonisolated enum PhotoIndexingPhase: Equatable {
    case waitingForLibrary, preparing, ready, indexing, pausing, paused, finished, failed
}

/// Owns the database and exactly one worker for the lifetime of the library.
/// Cancelling invalidates delivery immediately, but the slot stays occupied until
/// inference has returned, its tickets have been released, and models unloaded.
@MainActor
@Observable
final class PhotoIndexingStore {
    private(set) var phase: PhotoIndexingPhase = .waitingForLibrary
    private(set) var summary: PhotoIndexSummary = .empty
    private(set) var message: String?
    private(set) var currentStage: PhotoIndexStage?
    private(set) var wantsToRun = false
    /// Armed only by Start/Continue/Retry for this app session. An empty queue
    /// does not disarm updates, but must never spin up another empty worker.
    private(set) var followsLibraryChanges = false
    private(set) var isBusy = false

    @ObservationIgnored private let provider: any PhotoOCRSourceProviding
    @ObservationIgnored private let processor: any PhotoIndexProcessing
    @ObservationIgnored private let openStore: @Sendable () async throws -> PhotoIndexStore
    @ObservationIgnored private let isCurrentAndAccessible: @MainActor (LibraryPhoto) -> Bool
    @ObservationIgnored private var database: PhotoIndexStore?
    @ObservationIgnored private var photos: [LibraryPhoto]?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var synchronizedRevision: Int?
    @ObservationIgnored private var synchronizedVersions: PhotoIndexVersions?
    @ObservationIgnored private var mustClear = false
    @ObservationIgnored private var retryRequested = false
    @ObservationIgnored private var cloudRecheckRequested = false
    @ObservationIgnored private var invalidatedAssets: [String: UUID] = [:]
    @ObservationIgnored private var fullInvalidation: UUID?
    @ObservationIgnored private var blocked = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var sourceRequest: PhotoIndexSourceRequest?

    convenience init() {
        let checker = PhotoKitOCRDataRequester()
        self.init(provider: PhotoKitOCRSourceProvider(), processor: PhotoIndexProcessor(), openStore: {
            try await Task.detached { try PhotoIndexStore.openDefault() }.value
        }, isCurrentAndAccessible: { checker.isCurrentAndAccessible($0) })
    }

    init(
        provider: any PhotoOCRSourceProviding,
        processor: any PhotoIndexProcessing,
        openStore: @escaping @Sendable () async throws -> PhotoIndexStore,
        isCurrentAndAccessible: @escaping @MainActor (LibraryPhoto) -> Bool
    ) {
        self.provider = provider
        self.processor = processor
        self.openStore = openStore
        self.isCurrentAndAccessible = isCurrentAndAccessible
    }

    isolated deinit {
        worker?.cancel()
        sourceRequest?.cancel()
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if !active {
            // A fresh permitted snapshot is required after every inactive period.
            invalidateLibrary()
        } else {
            blocked = false
            if followsLibraryChanges {
                wantsToRun = true
                cloudRecheckRequested = true
            }
            kick()
        }
    }

    /// Content changes can be meaningful even when dates/dimensions are equal.
    /// Tokens keep a second notification for the same asset from being consumed
    /// by an older reconciliation which was still committing when it arrived.
    func libraryDidChange(_ change: PhotoLibraryChange) {
        for id in change.contentChangedIDs { invalidatedAssets[id] = UUID() }
        if change.requiresFullReindex { fullInvalidation = UUID() }
        invalidateLibrary()
    }

    func invalidateLibrary() {
        revision += 1
        photos = nil
        synchronizedRevision = nil
        summary = .empty
        message = nil
        stopWorker()
        phase = worker == nil ? .waitingForLibrary : .pausing
    }

    func updatePhotos(_ photos: [LibraryPhoto]) {
        revision += 1
        self.photos = photos
        synchronizedRevision = nil
        summary = .empty
        blocked = false
        message = nil
        if followsLibraryChanges { wantsToRun = true }
        stopWorker()
        kick()
    }

    func revokeAccess() {
        wantsToRun = false
        followsLibraryChanges = false
        retryRequested = false
        cloudRecheckRequested = false
        invalidatedAssets.removeAll()
        fullInvalidation = nil
        mustClear = true
        blocked = false
        invalidateLibrary()
        kick()
    }

    func start() {
        wantsToRun = true
        followsLibraryChanges = true
        cloudRecheckRequested = true
        blocked = false
        message = nil
        kick()
    }

    func pause() {
        wantsToRun = false
        followsLibraryChanges = false
        retryRequested = false
        cloudRecheckRequested = false
        stopWorker()
        phase = worker == nil ? .paused : .pausing
    }

    /// Explicit retry includes failures; ordinary foreground retries include only
    /// cloud-only stages. Neither path retries repeatedly within the same run.
    func retry() {
        guard worker == nil else { return }
        retryRequested = true
        start()
    }

    /// Explicit fallback for a content change missed while the app was closed.
    /// This discards only derived results, preserving the user's Photos library.
    func rebuild() {
        fullInvalidation = UUID()
        revision += 1
        synchronizedRevision = nil
        summary = .empty
        stopWorker()
        start()
    }

    func waitForIdle() async {
        while let worker { await worker.value }
    }

    /// Capture library authorization before query inference, and use the sole
    /// database owner so searching never resets an in-progress indexing ticket.
    func search(limit: Int = 50, prepareQuery: () async throws -> PreparedQuery) async throws -> [PhotoSearchMatch] {
        try Task.checkCancellation()
        guard (1...ReciprocalRankFusion.candidateLimit).contains(limit) else {
            throw PhotoSearchError.invalidLimit
        }
        guard isActive, !mustClear, synchronizedRevision == revision,
              let versions = synchronizedVersions, let database else {
            throw PhotoSearchError.indexNotReady
        }
        let searchRevision = revision
        let query = try await prepareQuery()
        try checkSearch(searchRevision)
        guard query.embedding.modelID == versions.embedding else {
            throw CLIPEmbeddingError.incompatibleModels
        }
        let matches = try await database.search(query, ocrVersion: versions.ocr, limit: limit)
        try checkSearch(searchRevision)
        // PhotoKit can reveal a removed/edited asset before its observer event.
        // Do not return its OCR text or scores merely because the index contains it.
        let accessible = try matches.filter {
            try checkSearch(searchRevision)
            return isCurrentAndAccessible($0.photo)
        }
        try checkSearch(searchRevision)
        return accessible
    }

    private func checkSearch(_ searchRevision: Int) throws {
        try checkCurrent(searchRevision)
        guard !mustClear, synchronizedRevision == searchRevision else { throw CancellationError() }
    }

    private func stopWorker() {
        worker?.cancel()
        sourceRequest?.cancel()
    }

    private func kick() {
        guard worker == nil, isActive, !blocked, mustClear || photos != nil else { return }
        guard mustClear || synchronizedRevision != revision || retryRequested || cloudRecheckRequested || wantsToRun else { return }
        let runRevision = revision
        phase = synchronizedRevision == revision ? .indexing : .preparing
        isBusy = true
        worker = Task { [weak self] in
            guard let self else { return }
            await self.run(revision: runRevision)
            self.worker = nil
            self.isBusy = false
            self.currentStage = nil
            self.kick()
        }
    }

    private func checkCurrent(_ runRevision: Int) throws {
        try Task.checkCancellation()
        guard isActive, revision == runRevision else { throw CancellationError() }
    }

    private func run(revision runRevision: Int) async {
        do {
            // Keep one store owner even when opening races a pause. Reopening would
            // incorrectly recover tickets belonging to an existing connection.
            if database == nil { database = try await openStore() }
            guard let database else { throw PhotoIndexError.closed }
            try checkCurrent(runRevision)
            if mustClear {
                try await database.clear()
                try checkCurrent(runRevision)
                mustClear = false
            }
            guard let photos else {
                phase = .waitingForLibrary
                return
            }
            // Prune stale content as well as lost access before loading models.
            // A model error must not leave old OCR searchable for an edited photo.
            let invalidations = invalidatedAssets
            let fullToken = fullInvalidation
            try await database.pruneStaleRecords(matching: photos,
                invalidatedAssetIDs: Set(invalidations.keys), invalidateAll: fullToken != nil)
            // Acknowledge only the notifications included in this committed pass.
            // Newer events, including ones for the same ID, remain pending.
            for (id, token) in invalidations where invalidatedAssets[id] == token {
                invalidatedAssets.removeValue(forKey: id)
            }
            if fullInvalidation == fullToken { fullInvalidation = nil }
            try checkCurrent(runRevision)
            try await database.recoverInterruptedWork()
            let versions = try await processor.versions()
            try checkCurrent(runRevision)
            try await database.synchronize(photos, versions: versions)
            try checkCurrent(runRevision)
            if retryRequested {
                try await database.retryIncomplete()
                try checkCurrent(runRevision)
                retryRequested = false
                cloudRecheckRequested = false
            } else if cloudRecheckRequested {
                // Once per explicit start or foreground cycle. Ordinary observer
                // refreshes do not retry cloud assets or permanent processing errors.
                try await database.retryDownloads()
                try checkCurrent(runRevision)
                cloudRecheckRequested = false
            }
            synchronizedVersions = versions
            synchronizedRevision = runRevision
            try await updateSummary(database, revision: runRevision)
            if wantsToRun {
                phase = .indexing
                // Bounded pages and one photo at a time. Source bytes are reused
                // for its two stages and released before the next source request.
                while wantsToRun {
                    try checkCurrent(runRevision)
                    let page = try await database.recordsNeedingWork(limit: 20)
                    try checkCurrent(runRevision)
                    if page.isEmpty { break }
                    for record in page {
                        try checkCurrent(runRevision)
                        try await process(record, database: database, revision: runRevision)
                    }
                }
                try checkCurrent(runRevision)
                wantsToRun = false
                phase = .finished
            } else {
                phase = summary.pendingCount == 0 ? .finished : .ready
            }
        } catch is CancellationError {
            // Cleanup has a fresh cancellation context, including after a source
            // callback was cancelled. A device lock can still make storage fail.
            if isActive, photos != nil {
                phase = wantsToRun ? .preparing : .paused
            } else {
                phase = .waitingForLibrary
            }
        } catch {
            if revision == runRevision, isActive {
                blocked = true
                wantsToRun = false
                followsLibraryChanges = false
                synchronizedRevision = nil
                summary = .empty
                phase = .failed
                message = (error as? PhotoIndexError)?.errorDescription
                    ?? "Не удалось подготовить обработку фотографий. Попробуйте снова."
            }
        }
        await processor.unload()
        // Refresh counts after a manual pause without inheriting cancellation.
        if revision == runRevision, isActive, synchronizedRevision == runRevision, let database {
            do {
                let updated = try await Task.detached { try await database.summary() }.value
                if revision == runRevision, isActive { summary = updated }
            } catch {
                if revision == runRevision, isActive {
                    summary = .empty
                    synchronizedRevision = nil
                    blocked = true
                    wantsToRun = false
                    followsLibraryChanges = false
                    phase = .failed
                    message = "Локальный индекс временно недоступен. Разблокируйте iPhone и попробуйте снова."
                }
            }
        }
    }

    private func updateSummary(_ database: PhotoIndexStore, revision: Int) async throws {
        let updated = try await database.summary()
        try checkCurrent(revision)
        summary = updated
    }

    private enum AssetChanged: Error { case unavailable }

    private func checkAsset(_ photo: LibraryPhoto, revision: Int) throws {
        try checkCurrent(revision)
        guard isCurrentAndAccessible(photo) else { throw AssetChanged.unavailable }
    }

    private func process(_ record: PhotoIndexRecord, database: PhotoIndexStore, revision: Int) async throws {
        var tickets: [PhotoIndexWork] = []
        var progressRecord = record
        do {
            try checkAsset(record.photo, revision: revision)
            for stage in PhotoIndexStage.allCases {
                let state = stage == .embedding ? record.embedding : record.ocr
                if state.status == .pending {
                    tickets.append(try await database.beginWork(for: record.photo.id, stage: stage))
                    try checkAsset(record.photo, revision: revision)
                }
            }
            let request = PhotoIndexSourceRequest(provider: provider)
            sourceRequest = request
            currentStage = nil
            let result = try await request.source(for: record.photo)
            sourceRequest = nil
            try checkAsset(record.photo, revision: revision)
            // Iterate a copy; completed tickets are no longer cancellation targets.
            for ticket in tickets {
                try checkAsset(record.photo, revision: revision)
                switch result {
                case .requiresDownload:
                    try await database.markRequiresDownload(ticket)
                case .unavailable:
                    try await database.fail(ticket, with: .sourceUnavailable)
                case .source(let source):
                    currentStage = ticket.stage
                    try await processStage(ticket, source: source, photo: record.photo,
                                           database: database, revision: revision)
                }
                tickets.removeAll { $0 == ticket }
                try checkAsset(record.photo, revision: revision)
                guard let updated = try await database.record(for: record.photo.id) else {
                    throw PhotoIndexError.staleWork
                }
                try checkCurrent(revision)
                updateProgress(from: progressRecord, to: updated)
                progressRecord = updated
            }
        } catch {
            sourceRequest?.cancel()
            sourceRequest = nil
            if error is AssetChanged {
                // A final PhotoKit check can detect revocation before a library
                // observer delivers its event. Remove all derived data for that ID.
                try await Task.detached { try await database.remove(assetIDs: [record.photo.id]) }.value
                if self.revision == revision, isActive { updateProgress(from: progressRecord, to: nil) }
                return
            }
            for ticket in tickets {
                do { try await database.cancel(ticket) }
                catch PhotoIndexError.staleWork { }
                catch {
                    // If locked, recovery is retried only after this worker drains
                    // and a fresh foreground snapshot is available.
                    synchronizedRevision = nil
                    throw error
                }
            }
            throw error
        }
    }

    /// Account for just the changed row between exact start/stop summaries. Scanning
    /// the whole database after each stage would make progress accounting quadratic.
    private func updateProgress(from old: PhotoIndexRecord, to new: PhotoIndexRecord?) {
        func counts(_ record: PhotoIndexRecord?) -> [Int] {
            guard let record else { return Array(repeating: 0, count: 7) }
            let statuses = [record.embedding.status, record.ocr.status]
            return [1, statuses.allSatisfy { $0 == .complete } ? 1 : 0,
                    record.embedding.status == .complete ? 1 : 0, record.ocr.status == .complete ? 1 : 0,
                    statuses.contains { $0 == .pending || $0 == .processing } ? 1 : 0,
                    statuses.contains(.requiresDownload) ? 1 : 0, statuses.contains(.failed) ? 1 : 0]
        }
        let before = counts(old), after = counts(new)
        let current = [summary.totalCount, summary.completeCount, summary.embeddingCount, summary.ocrCount,
                       summary.pendingCount, summary.downloadRequiredCount, summary.failedCount]
        let values = current.indices.map { current[$0] - before[$0] + after[$0] }
        summary = PhotoIndexSummary(totalCount: values[0], completeCount: values[1], embeddingCount: values[2],
                                    ocrCount: values[3], pendingCount: values[4], downloadRequiredCount: values[5],
                                    failedCount: values[6])
    }

    private func processStage(
        _ ticket: PhotoIndexWork, source: PhotoOCRSource, photo: LibraryPhoto,
        database: PhotoIndexStore, revision: Int
    ) async throws {
        // Separate model errors from persistence errors: a database failure stops
        // the run instead of marking every remaining photo as a processing failure.
        switch ticket.stage {
        case .embedding:
            let result: Result<CLIPEmbedding, Error>
            do { result = .success(try await processor.embedding(source)) }
            catch { result = .failure(error) }
            try checkAsset(photo, revision: revision)
            switch result {
            case .success(let embedding): try await database.saveEmbedding(embedding, for: ticket)
            case .failure(let error):
                if error is CancellationError { throw error }
                try await database.fail(ticket, with: Self.failure(error))
            }
        case .ocr:
            let result: Result<PhotoOCRResult, Error>
            do { result = .success(try await processor.recognize(source)) }
            catch { result = .failure(error) }
            try checkAsset(photo, revision: revision)
            switch result {
            case .success(let ocr): try await database.saveOCR(ocr, for: ticket)
            case .failure(let error):
                if error is CancellationError { throw error }
                try await database.fail(ticket, with: Self.failure(error))
            }
        }
    }

    private static func failure(_ error: Error) -> PhotoIndexFailure {
        switch error {
        case PhotoOCRError.invalidImage, CLIPImagePreprocessingError.invalidImage,
             CLIPImagePreprocessingError.invalidOrientation, CLIPImagePreprocessingError.unsupportedPixelFormat:
            .invalidImage
        case PhotoOCRError.imageTooLarge, CLIPImagePreprocessingError.imageTooLarge: .tooLarge
        case PhotoOCRError.unsupportedLanguages: .unsupportedLanguages
        case is CLIPModelResourceError: .modelUnavailable
        default: .processingFailed
        }
    }
}
