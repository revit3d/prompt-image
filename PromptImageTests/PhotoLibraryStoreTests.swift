import Foundation
import Photos
import Testing
import UIKit
@testable import PromptImage

@MainActor
struct PhotoLibraryStoreTests {
    @Test(arguments: [PHAuthorizationStatus.notDetermined, .denied, .restricted])
    func inaccessibleLibraryDoesNotFetchOrObserve(status: PHAuthorizationStatus) {
        let fixture = LibraryFixture(status: status)

        fixture.store.refresh()

        #expect(fixture.provider.requestCount == 0)
        #expect(fixture.provider.startCount == 0)
        #expect(fixture.store.photos.isEmpty)
        #expect(!fixture.store.isLoading)
        #expect(fixture.authorization.requestCount == 0)
    }

    @Test(arguments: [PHAuthorizationStatus.authorized, .limited])
    func permittedLibraryLoadsWithoutPrompting(status: PHAuthorizationStatus) async {
        let fixture = LibraryFixture(status: status)
        let photo = samplePhoto("first")

        fixture.store.refresh()
        await fixture.provider.waitUntilRequested(1)
        #expect(fixture.store.isLoading)
        fixture.provider.complete(1, with: [photo])
        await fixture.provider.waitUntilReturned(1)

        #expect(fixture.store.photos == [photo])
        #expect(!fixture.store.isLoading)
        #expect(fixture.provider.startCount == 1)
        #expect(fixture.authorization.requestCount == 0)
        #expect(fixture.store.availability.totalCount == 1)
        #expect(!fixture.store.availability.hasStarted)
    }

    @Test
    func revocationCancelsAnActiveSourceAvailabilityCheck() async {
        let fixture = LibraryFixture(status: .authorized)
        await fixture.load([samplePhoto("pending")])
        fixture.store.availability.start()
        await fixture.availability.waitUntilRequested()

        fixture.authorization.status = .denied
        fixture.store.refresh()

        #expect(fixture.availability.cancelCount == 1)
        #expect(fixture.store.availability.totalCount == 0)
        #expect(fixture.store.availability.results.isEmpty)
        #expect(!fixture.store.availability.isRunning)
        #expect(!fixture.store.availability.hasStarted)
    }

    @Test
    func observerRefreshesChangedSelectionWhilePermissionRemainsLimited() async {
        let fixture = LibraryFixture(status: .limited)
        let original = samplePhoto("original")
        await fixture.load([original])

        fixture.provider.sendChange()
        await fixture.provider.waitUntilRequested(2)
        #expect(fixture.store.photos == [original])
        fixture.provider.complete(2, with: [samplePhoto("replacement")])
        await fixture.provider.waitUntilReturned(2)

        #expect(fixture.store.photos.map(\.id) == ["replacement"])
        #expect(fixture.store.access.status == .limited)
        #expect(fixture.provider.startCount == 1)
    }

    @Test
    func overlappingRefreshesCoalesceAndDoNotPublishSupersededResults() async {
        let fixture = LibraryFixture(status: .authorized)
        fixture.store.refresh()
        await fixture.provider.waitUntilRequested(1)

        fixture.store.refresh()
        fixture.store.refresh()
        fixture.provider.sendChange()
        #expect(fixture.provider.requestCount == 1)

        fixture.provider.complete(1, with: [samplePhoto("outdated")])
        await fixture.provider.waitUntilRequested(2)
        #expect(fixture.store.photos.isEmpty)
        #expect(fixture.store.isLoading)
        fixture.provider.complete(2, with: [samplePhoto("latest")])
        await fixture.provider.waitUntilReturned(2)

        #expect(fixture.provider.requestCount == 2)
        #expect(fixture.store.photos.map(\.id) == ["latest"])
        #expect(!fixture.store.isLoading)
    }

    @Test
    func revocationClearsPhotosSelectionAndRequests() async {
        let fixture = LibraryFixture(status: .authorized)
        let photo = samplePhoto("first")
        await fixture.load([photo])
        fixture.store.selectedPhoto = photo

        fixture.authorization.status = .denied
        fixture.store.refresh()

        #expect(fixture.store.photos.isEmpty)
        #expect(fixture.store.selectedPhoto == nil)
        #expect(!fixture.store.isLoading)
        #expect(fixture.images.cancelAllCount == 1)
        #expect(fixture.provider.stopCount == 1)
        #expect(fixture.provider.requestCount == 1)
    }

    @Test
    func revokedPendingRequestCannotOverwriteAReauthorizedLibrary() async {
        let fixture = LibraryFixture(status: .authorized)
        fixture.store.refresh()
        await fixture.provider.waitUntilRequested(1)

        fixture.authorization.status = .denied
        fixture.store.refresh()
        fixture.authorization.status = .limited
        fixture.store.refresh()
        await fixture.provider.waitUntilRequested(2)
        fixture.provider.complete(2, with: [samplePhoto("permitted")])
        await fixture.provider.waitUntilReturned(2)

        fixture.provider.complete(1, with: [samplePhoto("revoked")])
        await fixture.provider.waitUntilReturned(1)

        #expect(fixture.store.photos.map(\.id) == ["permitted"])
        #expect(fixture.provider.startCount == 2)
        #expect(fixture.provider.stopCount == 1)
        #expect(!fixture.store.isLoading)
    }

    @Test
    func fetchCompletionRechecksPermissionEvenWithoutAnObserverEvent() async {
        let fixture = LibraryFixture(status: .authorized)
        fixture.store.refresh()
        await fixture.provider.waitUntilRequested(1)

        fixture.authorization.status = .restricted
        fixture.provider.complete(1, with: [samplePhoto("revoked")])
        await fixture.provider.waitUntilReturned(1)

        #expect(fixture.store.photos.isEmpty)
        #expect(fixture.store.access.status == .restricted)
        #expect(fixture.provider.stopCount == 1)
        #expect(fixture.images.cancelAllCount == 1)
        #expect(!fixture.store.isLoading)
    }

    @Test
    func narrowingAccessDuringFetchDiscardsTheFullLibraryResult() async {
        let fixture = LibraryFixture(status: .authorized)
        fixture.store.refresh()
        await fixture.provider.waitUntilRequested(1)

        fixture.authorization.status = .limited
        fixture.provider.complete(1, with: [samplePhoto("no-longer-permitted")])
        await fixture.provider.waitUntilRequested(2)
        #expect(fixture.store.photos.isEmpty)

        fixture.provider.complete(2, with: [samplePhoto("selected")])
        await fixture.provider.waitUntilReturned(2)
        #expect(fixture.store.photos.map(\.id) == ["selected"])
        #expect(fixture.store.access.status == .limited)
    }

    @Test
    func narrowingAccessImmediatelyClearsDisplayedPhotosWhileARefreshIsPending() async {
        let fixture = LibraryFixture(status: .authorized)
        let original = samplePhoto("previously-visible")
        await fixture.load([original])
        fixture.store.selectedPhoto = original
        fixture.store.refresh()
        await fixture.provider.waitUntilRequested(2)

        fixture.authorization.status = .limited
        // The view may refresh the shared authorization model before the store.
        fixture.store.access.refresh()
        fixture.store.refresh()

        #expect(fixture.store.photos.isEmpty)
        #expect(fixture.store.selectedPhoto == nil)
        #expect(fixture.images.cancelAllCount == 1)
        #expect(fixture.store.isLoading)
        #expect(fixture.provider.requestCount == 2)

        fixture.provider.complete(2, with: [original])
        await fixture.provider.waitUntilRequested(3)
        #expect(fixture.store.photos.isEmpty)
        fixture.provider.complete(3, with: [samplePhoto("permitted")])
        await fixture.provider.waitUntilReturned(3)

        #expect(fixture.store.photos.map(\.id) == ["permitted"])
        #expect(fixture.store.selectedPhoto == nil)
        #expect(fixture.images.cancelAllCount == 1)
        #expect(fixture.provider.startCount == 1)
        #expect(!fixture.store.isLoading)
    }

    @Test
    func selectionTracksEditsAndClosesWhenThePhotoIsRemoved() async {
        let fixture = LibraryFixture(status: .authorized)
        let original = samplePhoto("selected")
        let edited = samplePhoto("selected", modificationDate: Date(timeIntervalSince1970: 100))
        await fixture.load([original])
        fixture.store.selectedPhoto = original

        await fixture.load([edited])
        #expect(fixture.store.selectedPhoto == edited)

        await fixture.load([])
        #expect(fixture.store.selectedPhoto == nil)
        #expect(fixture.store.photos.isEmpty)
        #expect(!fixture.store.isLoading)
    }
}

@MainActor
private func samplePhoto(_ id: String, modificationDate: Date? = nil) -> LibraryPhoto {
    LibraryPhoto(id: id, creationDate: nil, modificationDate: modificationDate, pixelWidth: 100, pixelHeight: 200)
}

@MainActor
private struct LibraryFixture {
    let authorization: LibraryAuthorizationStub
    let provider = LibraryProviderStub()
    let images = LibraryImagesStub()
    let availability = LibraryAvailabilityStub()
    let store: PhotoLibraryStore

    init(status: PHAuthorizationStatus) {
        authorization = LibraryAuthorizationStub(status: status)
        store = PhotoLibraryStore(
            access: PhotoLibraryAccess(provider: authorization),
            provider: provider,
            images: images,
            availability: PhotoAvailabilityScan(provider: availability)
        )
    }

    func load(_ photos: [LibraryPhoto]) async {
        let request = provider.requestCount + 1
        store.refresh()
        await provider.waitUntilRequested(request)
        provider.complete(request, with: photos)
        await provider.waitUntilReturned(request)
    }
}

@MainActor
private final class LibraryAvailabilityStub: PhotoAvailabilityProviding {
    private var wasRequested = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var cancelCount = 0

    func checkAvailability(
        of photo: LibraryPhoto,
        completion: @escaping @MainActor (PhotoAvailability) -> Void
    ) -> UUID {
        wasRequested = true
        waiter?.resume()
        waiter = nil
        return UUID()
    }

    func cancel(_ requestID: UUID) { cancelCount += 1 }

    func waitUntilRequested() async {
        guard !wasRequested else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

@MainActor
private final class LibraryAuthorizationStub: PhotoLibraryAuthorizing {
    var status: PHAuthorizationStatus
    private(set) var requestCount = 0

    init(status: PHAuthorizationStatus) { self.status = status }
    func authorizationStatus() -> PHAuthorizationStatus { status }
    func requestAuthorization() async -> PHAuthorizationStatus {
        requestCount += 1
        return status
    }
}

@MainActor
private final class LibraryProviderStub: PhotoLibraryProviding {
    private(set) var requestCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var onChange: (@MainActor @Sendable () -> Void)?
    private var pending: [Int: CheckedContinuation<[LibraryPhoto], Never>] = [:]
    private var requestedWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var returnedWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var returned: Set<Int> = []

    func photos() async -> [LibraryPhoto] {
        requestCount += 1
        let request = requestCount
        let photos = await withCheckedContinuation { continuation in
            pending[request] = continuation
            requestedWaiters.removeValue(forKey: request)?.resume()
        }
        returned.insert(request)
        returnedWaiters.removeValue(forKey: request)?.resume()
        return photos
    }

    func startObserving(_ onChange: @escaping @MainActor @Sendable () -> Void) {
        startCount += 1
        self.onChange = onChange
    }

    func stopObserving() {
        stopCount += 1
        onChange = nil
    }

    func sendChange() { onChange?() }

    func waitUntilRequested(_ request: Int) async {
        guard requestCount < request else { return }
        await withCheckedContinuation { requestedWaiters[request] = $0 }
    }

    func waitUntilReturned(_ request: Int) async {
        guard !returned.contains(request) else { return }
        await withCheckedContinuation { returnedWaiters[request] = $0 }
    }

    func complete(_ request: Int, with photos: [LibraryPhoto]) {
        pending.removeValue(forKey: request)?.resume(returning: photos)
    }
}

@MainActor
private final class LibraryImagesStub: PhotoImageProviding {
    private(set) var cancelAllCount = 0

    func requestImage(
        for photo: LibraryPhoto,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        completion: @escaping @MainActor (PhotoImageResult) -> Void
    ) -> PHImageRequestID {
        PHInvalidImageRequestID
    }

    func cancelRequest(_ requestID: PHImageRequestID) { }
    func cancelAll() { cancelAllCount += 1 }
}
