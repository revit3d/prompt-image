import Photos
import Testing
import UIKit
@testable import PromptImage

@MainActor
struct PhotoImageLoaderTests {
    @Test
    func requestUsesThePhotoAndDisplaySize() {
        let provider = ImageProviderStub()
        let loader = PhotoImageLoader(provider: provider)
        let photo = makePhoto("selected")
        let size = CGSize(width: 900, height: 600)

        loader.load(photo: photo, targetSize: size, contentMode: .aspectFit)

        #expect(loader.result == nil)
        #expect(provider.requests.count == 1)
        #expect(provider.requests.first?.photo == photo)
        #expect(provider.requests.first?.targetSize == size)
        #expect(provider.requests.first?.contentMode == .aspectFit)
    }

    @Test
    func replacingAPendingRequestCancelsItAndIgnoresItsLateImage() {
        let provider = ImageProviderStub()
        let loader = PhotoImageLoader(provider: provider)
        let currentImage = UIImage()

        load("old", into: loader)
        load("new", into: loader)

        #expect(provider.cancelledRequests == [1])
        #expect(loader.result == nil)

        provider.complete(2, with: .image(currentImage))
        provider.complete(1, with: .image(UIImage()))

        guard case .image(let displayedImage) = loader.result else {
            Issue.record("The latest photo should remain displayed after an old callback.")
            return
        }
        #expect(displayedImage === currentImage)
    }

    @Test
    func anOldTerminalResultCannotStopTheCurrentRequest() {
        let provider = ImageProviderStub()
        let loader = PhotoImageLoader(provider: provider)

        load("old", into: loader)
        load("new", into: loader)
        provider.complete(1, with: .cloudOnly)

        #expect(loader.result == nil)

        loader.cancel()

        #expect(provider.cancelledRequests == [1, 2])
    }

    @Test
    func cancelStopsThePendingRequestAndIgnoresItsCallback() {
        let provider = ImageProviderStub()
        let loader = PhotoImageLoader(provider: provider)

        load("pending", into: loader)
        loader.cancel()
        loader.cancel()
        provider.complete(1, with: .image(UIImage()))

        #expect(loader.result == nil)
        #expect(provider.cancelledRequests == [1])
    }

    @Test
    func cancelClearsTheDisplayedImageWithoutCancellingACompletedRequest() {
        let provider = ImageProviderStub()
        let loader = PhotoImageLoader(provider: provider)

        load("visible", into: loader)
        provider.complete(1, with: .image(UIImage()))
        #expect(loader.result != nil)

        loader.cancel()

        #expect(loader.result == nil)
        #expect(provider.cancelledRequests.isEmpty)
    }

    @Test
    func selectingAnotherPhotoClearsThePreviousImageWhileLoading() {
        let provider = ImageProviderStub()
        let loader = PhotoImageLoader(provider: provider)

        load("visible", into: loader)
        provider.complete(1, with: .image(UIImage()))
        load("next", into: loader)

        #expect(loader.result == nil)
        #expect(provider.requests.count == 2)
        #expect(provider.cancelledRequests.isEmpty)
    }

    @Test(arguments: [true, false])
    func terminalFailureEndsLoadingWithoutLeavingAPendingRequest(cloudOnly: Bool) {
        let provider = ImageProviderStub()
        let loader = PhotoImageLoader(provider: provider)

        load("unavailable", into: loader)
        provider.complete(1, with: cloudOnly ? .cloudOnly : .unavailable)

        switch loader.result {
        case .cloudOnly:
            #expect(cloudOnly)
        case .unavailable:
            #expect(!cloudOnly)
        default:
            Issue.record("A terminal failure should replace the loading state.")
        }

        loader.cancel()

        #expect(loader.result == nil)
        #expect(provider.cancelledRequests.isEmpty)
    }

    @Test
    func synchronousCompletionDoesNotLeaveAPhantomPendingRequest() {
        let image = UIImage()
        let provider = ImageProviderStub(synchronousResult: .image(image))
        let loader = PhotoImageLoader(provider: provider)

        load("cached", into: loader)

        guard case .image(let displayedImage) = loader.result else {
            Issue.record("A synchronous image response should be displayed.")
            return
        }
        #expect(displayedImage === image)

        loader.cancel()

        #expect(loader.result == nil)
        #expect(provider.cancelledRequests.isEmpty)
    }

    private func load(_ id: String, into loader: PhotoImageLoader) {
        loader.load(
            photo: makePhoto(id),
            targetSize: CGSize(width: 240, height: 240),
            contentMode: .aspectFill
        )
    }

    private func makePhoto(_ id: String) -> LibraryPhoto {
        LibraryPhoto(
            id: id,
            creationDate: nil,
            modificationDate: nil,
            pixelWidth: 1_200,
            pixelHeight: 800
        )
    }
}

@MainActor
private final class ImageProviderStub: PhotoImageProviding {
    struct Request {
        let id: PHImageRequestID
        let photo: LibraryPhoto
        let targetSize: CGSize
        let contentMode: PHImageContentMode
        let completion: @MainActor (PhotoImageResult) -> Void
    }

    private(set) var requests: [Request] = []
    private(set) var cancelledRequests: [PHImageRequestID] = []
    private let synchronousResult: PhotoImageResult?

    init(synchronousResult: PhotoImageResult? = nil) {
        self.synchronousResult = synchronousResult
    }

    func requestImage(
        for photo: LibraryPhoto,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        completion: @escaping @MainActor (PhotoImageResult) -> Void
    ) -> PHImageRequestID {
        let id = PHImageRequestID(requests.count + 1)
        requests.append(Request(
            id: id,
            photo: photo,
            targetSize: targetSize,
            contentMode: contentMode,
            completion: completion
        ))
        if let synchronousResult {
            completion(synchronousResult)
        }
        return id
    }

    func cancelRequest(_ id: PHImageRequestID) {
        cancelledRequests.append(id)
    }

    func cancelAll() {
        for request in requests where !cancelledRequests.contains(request.id) {
            cancelRequest(request.id)
        }
    }

    func complete(_ id: PHImageRequestID, with result: PhotoImageResult) {
        // Retain callbacks so tests can simulate PhotoKit delivering a cancelled request.
        requests.first(where: { $0.id == id })?.completion(result)
    }
}
