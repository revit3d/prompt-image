import Foundation
import Testing
@testable import PromptImage

@MainActor
struct PhotoAvailabilityScanTests {
    @Test
    func updatingPhotosWaitsForTheUserToStart() async {
        let provider = AvailabilityProviderStub()
        let scan = PhotoAvailabilityScan(provider: provider)

        scan.updatePhotos([availabilityPhoto("one"), availabilityPhoto("two")])
        await drainAvailabilityTasks()

        #expect(provider.requestCount == 0)
        #expect(scan.totalCount == 2)
        #expect(scan.uncheckedCount == 2)
        #expect(scan.checkedCount == 0)
        #expect(!scan.hasStarted)
        #expect(!scan.isRunning)
    }

    @Test
    func checksSequentiallyAndReportsPartialCounts() async {
        let provider = AvailabilityProviderStub()
        let scan = PhotoAvailabilityScan(provider: provider)
        scan.updatePhotos((1...3).map { availabilityPhoto("\($0)") })

        scan.start()
        #expect(scan.isRunning)
        await provider.waitUntilRequested(1)
        scan.start()
        #expect(provider.requestCount == 1)
        provider.complete(1, with: .local)
        await provider.waitUntilRequested(2)

        #expect(scan.checkedCount == 1)
        #expect(scan.localCount == 1)
        #expect(scan.uncheckedCount == 2)
        provider.complete(2, with: .requiresDownload)
        await provider.waitUntilRequested(3)
        #expect(scan.downloadRequiredCount == 1)
        #expect(scan.skippedCount == 1)
        provider.complete(3, with: .unavailable)
        await waitForAvailability { !scan.isRunning }

        #expect(scan.checkedCount == 3)
        #expect(scan.uncheckedCount == 0)
        #expect(scan.unavailableCount == 1)
        #expect(scan.skippedCount == 2)
        #expect(provider.maximumActiveCount == 1)
        #expect(scan.hasStarted)
    }

    @Test
    func synchronousProviderDoesNotRecurseOrLoseResults() async {
        let provider = AvailabilityProviderStub(synchronousResult: .local)
        let scan = PhotoAvailabilityScan(provider: provider)
        scan.updatePhotos((0..<2_000).map { availabilityPhoto("\($0)") })

        scan.start()
        await provider.waitUntilRequested(2_000)
        await waitForAvailability { !scan.isRunning }

        #expect(scan.localCount == 2_000)
        #expect(scan.uncheckedCount == 0)
        #expect(provider.maximumRequestDepth == 1)
        #expect(provider.maximumActiveCount == 1)
    }

    @Test
    func pauseCancelsWithoutACallbackAndRejectsLateCompletion() async {
        let provider = AvailabilityProviderStub()
        let scan = PhotoAvailabilityScan(provider: provider)
        scan.updatePhotos([availabilityPhoto("one"), availabilityPhoto("two")])
        scan.start()
        await provider.waitUntilRequested(1)

        scan.pause()
        #expect(!scan.isRunning)
        #expect(scan.uncheckedCount == 2)
        #expect(provider.cancelledRequests == [1])
        provider.complete(1, with: .local)
        await drainAvailabilityTasks()
        #expect(scan.results.isEmpty)
        #expect(provider.requestCount == 1)

        scan.start()
        await provider.waitUntilRequested(2)
        #expect(provider.photos[1].id == "one")
        provider.complete(2, with: .requiresDownload)
        await provider.waitUntilRequested(3)
        #expect(scan.results["one"] == .requiresDownload)
        scan.pause()
    }

    @Test
    func inactivityResumesTheInterruptedPhotoButManualPauseDoesNot() async {
        let provider = AvailabilityProviderStub()
        let scan = PhotoAvailabilityScan(provider: provider)
        scan.updatePhotos([availabilityPhoto("one")])
        scan.start()
        await provider.waitUntilRequested(1)

        scan.setActive(false)
        #expect(!scan.isRunning)
        #expect(provider.cancelledRequests == [1])
        scan.setActive(true)
        await provider.waitUntilRequested(2)
        #expect(provider.photos[1].id == "one")
        scan.pause()
        scan.setActive(false)
        scan.setActive(true)
        await drainAvailabilityTasks()

        #expect(provider.requestCount == 2)
        #expect(!scan.isRunning)
        #expect(scan.uncheckedCount == 1)
    }

    @Test
    func startingWhileInactiveWaitsUntilActive() async {
        let provider = AvailabilityProviderStub()
        let scan = PhotoAvailabilityScan(provider: provider)
        scan.updatePhotos([availabilityPhoto("one")])
        scan.setActive(false)

        scan.start()
        await drainAvailabilityTasks()
        #expect(scan.hasStarted)
        #expect(!scan.isRunning)
        #expect(provider.requestCount == 0)
        scan.setActive(true)
        await provider.waitUntilRequested(1)
        scan.pause()
    }

    @Test
    func pauseBeforeTheScheduledStepDoesNotLaunchARequest() async {
        let provider = AvailabilityProviderStub()
        let scan = PhotoAvailabilityScan(provider: provider)
        scan.updatePhotos([availabilityPhoto("one")])

        scan.start()
        scan.pause()
        await drainAvailabilityTasks()

        #expect(provider.requestCount == 0)
        #expect(scan.uncheckedCount == 1)
        #expect(!scan.isRunning)
    }

    @Test
    func clearDropsPrivateStateAndRejectsAResultFromBeforeReauthorization() async {
        let provider = AvailabilityProviderStub()
        let scan = PhotoAvailabilityScan(provider: provider)
        let photo = availabilityPhoto("same-identifier")
        scan.updatePhotos([photo])
        scan.start()
        await provider.waitUntilRequested(1)

        scan.clear()
        #expect(scan.totalCount == 0)
        #expect(scan.results.isEmpty)
        #expect(!scan.hasStarted)
        #expect(!scan.isRunning)
        scan.updatePhotos([photo])
        await drainAvailabilityTasks()
        #expect(provider.requestCount == 1)
        scan.start()
        await provider.waitUntilRequested(2)
        provider.complete(1, with: .local)
        await drainAvailabilityTasks()
        #expect(scan.results.isEmpty)
        provider.complete(2, with: .requiresDownload)
        await waitForAvailability { !scan.isRunning }

        #expect(scan.localCount == 0)
        #expect(scan.downloadRequiredCount == 1)
    }

    @Test
    func identicalOrReorderedDescriptorsDoNotCancelThePendingProbe() async {
        let provider = AvailabilityProviderStub()
        let scan = PhotoAvailabilityScan(provider: provider)
        let first = availabilityPhoto("one")
        let second = availabilityPhoto("two")
        scan.updatePhotos([first, second])
        scan.start()
        await provider.waitUntilRequested(1)

        scan.updatePhotos([first, second])
        scan.updatePhotos([second, first])
        await drainAvailabilityTasks()

        #expect(provider.cancelledRequests.isEmpty)
        #expect(provider.requestCount == 1)
        provider.complete(1, with: .local)
        await provider.waitUntilRequested(2)
        #expect(provider.photos[1] == second)
        scan.pause()
    }

    @Test
    func reconciliationRetainsOnlyUnchangedCompletedPhotos() async {
        let provider = AvailabilityProviderStub()
        let scan = PhotoAvailabilityScan(provider: provider)
        let kept = availabilityPhoto("kept")
        let edited = availabilityPhoto("edited")
        let deleted = availabilityPhoto("deleted")
        scan.updatePhotos([kept, edited, deleted, availabilityPhoto("pending")])
        scan.start()
        await provider.waitUntilRequested(1)
        provider.complete(1, with: .local)
        await provider.waitUntilRequested(2)
        provider.complete(2, with: .requiresDownload)
        await provider.waitUntilRequested(3)
        provider.complete(3, with: .unavailable)
        await provider.waitUntilRequested(4)

        let changed = availabilityPhoto("edited", revision: 1)
        scan.updatePhotos([kept, changed, availabilityPhoto("new")])
        await provider.waitUntilRequested(5)
        #expect(provider.cancelledRequests == [4])
        #expect(provider.photos[4] == changed)
        #expect(scan.results == ["kept": .local])
        #expect(scan.totalCount == 3)
        #expect(scan.checkedCount == 1)
        #expect(scan.downloadRequiredCount == 0)
        #expect(scan.unavailableCount == 0)
        provider.complete(4, with: .local)
        await drainAvailabilityTasks()
        #expect(scan.results == ["kept": .local])
        provider.complete(5, with: .local)
        await provider.waitUntilRequested(6)
        #expect(provider.photos[5].id == "new")
        scan.pause()
    }

    @Test
    func completedScanChecksNewPhotosUnlessManuallyPaused() async {
        let provider = AvailabilityProviderStub(synchronousResult: .local)
        let scan = PhotoAvailabilityScan(provider: provider)
        let first = availabilityPhoto("one")
        scan.updatePhotos([first])
        scan.start()
        await provider.waitUntilRequested(1)
        await waitForAvailability { !scan.isRunning }

        scan.updatePhotos([first, availabilityPhoto("two")])
        await provider.waitUntilRequested(2)
        await waitForAvailability { !scan.isRunning }
        #expect(scan.localCount == 2)
        scan.pause()
        scan.updatePhotos([first, availabilityPhoto("two"), availabilityPhoto("three")])
        await drainAvailabilityTasks()

        #expect(provider.requestCount == 2)
        #expect(scan.checkedCount == 2)
        #expect(scan.uncheckedCount == 1)
        #expect(!scan.isRunning)
    }

    @Test
    func restartDiscardsCompletedResultsAndCancelsTheOldGeneration() async {
        let provider = AvailabilityProviderStub()
        let scan = PhotoAvailabilityScan(provider: provider)
        scan.updatePhotos([availabilityPhoto("one"), availabilityPhoto("two")])
        scan.start()
        await provider.waitUntilRequested(1)
        provider.complete(1, with: .local)
        await provider.waitUntilRequested(2)

        scan.restart()
        #expect(scan.results.isEmpty)
        #expect(scan.checkedCount == 0)
        #expect(scan.uncheckedCount == 2)
        await provider.waitUntilRequested(3)
        #expect(provider.cancelledRequests == [2])
        #expect(provider.photos[2].id == "one")
        provider.complete(2, with: .requiresDownload)
        await drainAvailabilityTasks()
        #expect(scan.results.isEmpty)
        scan.pause()
    }

    @Test
    func emptySnapshotsAreIdleAndAnEmptyUpdateDropsOldResults() async {
        let provider = AvailabilityProviderStub(synchronousResult: .local)
        let scan = PhotoAvailabilityScan(provider: provider)

        scan.updatePhotos([])
        scan.start()
        #expect(scan.totalCount == 0)
        #expect(scan.uncheckedCount == 0)
        #expect(!scan.isRunning)
        scan.updatePhotos([availabilityPhoto("one")])
        await provider.waitUntilRequested(1)
        await waitForAvailability { !scan.isRunning }
        scan.updatePhotos([])

        #expect(scan.results.isEmpty)
        #expect(scan.localCount == 0)
        #expect(scan.checkedCount == 0)
        #expect(scan.totalCount == 0)
        #expect(!scan.isRunning)
        scan.clear()
        scan.setActive(false)
        scan.setActive(true)
        await drainAvailabilityTasks()
        #expect(provider.requestCount == 1)
        #expect(!scan.hasStarted)
    }

    @Test
    func duplicateCallbacksCannotDoubleCountAResult() async {
        let provider = AvailabilityProviderStub()
        let scan = PhotoAvailabilityScan(provider: provider)
        scan.updatePhotos([availabilityPhoto("one")])
        scan.start()
        await provider.waitUntilRequested(1)

        provider.complete(1, with: .local)
        provider.complete(1, with: .requiresDownload)
        await waitForAvailability { !scan.isRunning }

        #expect(scan.results == ["one": .local])
        #expect(scan.checkedCount == 1)
        #expect(scan.localCount == 1)
        #expect(scan.downloadRequiredCount == 0)
    }
}

@MainActor
private func availabilityPhoto(_ id: String, revision: TimeInterval = 0) -> LibraryPhoto {
    LibraryPhoto(
        id: id,
        creationDate: nil,
        modificationDate: Date(timeIntervalSince1970: revision),
        pixelWidth: 100,
        pixelHeight: 200
    )
}

@MainActor
private func drainAvailabilityTasks() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private func waitForAvailability(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Availability scan did not reach the expected state")
}

@MainActor
private final class AvailabilityProviderStub: PhotoAvailabilityProviding {
    let synchronousResult: PhotoAvailability?
    private(set) var photos: [LibraryPhoto] = []
    private(set) var cancelledRequests: [Int] = []
    private(set) var maximumActiveCount = 0
    private(set) var maximumRequestDepth = 0
    private var requestDepth = 0
    private var activeRequests: Set<Int> = []
    private var identifiers: [UUID: Int] = [:]
    private var completions: [Int: @MainActor (PhotoAvailability) -> Void] = [:]
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    var requestCount: Int { photos.count }

    init(synchronousResult: PhotoAvailability? = nil) {
        self.synchronousResult = synchronousResult
    }

    func checkAvailability(
        of photo: LibraryPhoto,
        completion: @escaping @MainActor (PhotoAvailability) -> Void
    ) -> UUID {
        requestDepth += 1
        defer { requestDepth -= 1 }
        maximumRequestDepth = max(maximumRequestDepth, requestDepth)
        let id = UUID()
        photos.append(photo)
        let request = requestCount
        identifiers[id] = request
        completions[request] = completion
        activeRequests.insert(request)
        maximumActiveCount = max(maximumActiveCount, activeRequests.count)
        if let synchronousResult { complete(request, with: synchronousResult) }
        waiters.removeValue(forKey: request)?.resume()
        return id
    }

    func cancel(_ requestID: UUID) {
        guard let request = identifiers[requestID] else { return }
        activeRequests.remove(request)
        cancelledRequests.append(request)
        // Deliberately do not deliver a callback on cancellation.
    }

    func complete(_ request: Int, with result: PhotoAvailability) {
        activeRequests.remove(request)
        completions[request]?(result)
    }

    func waitUntilRequested(_ request: Int) async {
        guard requestCount < request else { return }
        await withCheckedContinuation { waiters[request] = $0 }
    }
}
