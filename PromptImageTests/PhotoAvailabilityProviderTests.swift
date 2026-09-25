import Foundation
import Photos
import Testing
@testable import PromptImage

@MainActor
struct PhotoAvailabilityProviderTests {
    @Test
    func requestUsesTheCurrentPhotoWithoutNetworkAccess() {
        let requester = DataRequesterStub()
        let provider = PhotoKitAvailabilityProvider(requester: requester)
        let photo = makePhoto("selected")

        let token = provider.checkAvailability(of: photo) { _ in }

        #expect(requester.requests.count == 1)
        #expect(requester.requests.first?.photo == photo)
        #expect(requester.requests.first?.options.version == .current)
        #expect(requester.requests.first?.options.isNetworkAccessAllowed == false)
        #expect(requester.requests.first?.options.isSynchronous == false)
        provider.cancel(token)
    }

    @Test(arguments: [true, false])
    func usableDataIsLocalEvenWhenAnICloudCopyExists(isInCloud: Bool) {
        expectAvailability(.local, from: response(hasData: true, isInCloud: isInCloud))
    }

    @Test
    func missingCloudDataRequiresADownload() {
        expectAvailability(.requiresDownload, from: response(isInCloud: true))
    }

    @Test(arguments: [true, false])
    func networkRequiredErrorDoesNotDependOnTheCloudFlag(isInCloud: Bool) {
        expectAvailability(
            .requiresDownload,
            from: response(isInCloud: isInCloud, hasError: true, needsNetwork: true)
        )
    }

    @Test(arguments: [true, false])
    func otherErrorsAreUnavailableEvenWhenAnICloudCopyExists(isInCloud: Bool) {
        expectAvailability(
            .unavailable,
            from: response(hasData: true, isInCloud: isInCloud, hasError: true)
        )
    }

    @Test(arguments: [true, false])
    func degradedDataCannotQualifyAsLocal(isInCloud: Bool) {
        expectAvailability(
            .unavailable,
            from: response(hasData: true, isDegraded: true, isInCloud: isInCloud)
        )
    }

    @Test
    func emptyResponseWithoutCloudOrErrorFlagsIsUnavailable() {
        expectAvailability(.unavailable, from: response())
    }

    @Test
    func unexpectedPhotoKitCancellationIsUnavailable() {
        expectAvailability(
            .unavailable,
            from: response(hasData: true, isInCloud: true, isCancelled: true)
        )
    }

    @Test
    func callerCancellationStopsTheRequestAndSuppressesLateCallbacks() {
        let requester = DataRequesterStub()
        let provider = PhotoKitAvailabilityProvider(requester: requester)
        var results: [PhotoAvailability] = []
        let token = provider.checkAvailability(of: makePhoto("cancelled")) { results.append($0) }

        provider.cancel(token)
        provider.cancel(token)
        requester.complete(1, with: response(isCancelled: true))
        requester.complete(1, with: response(hasData: true))

        #expect(requester.cancelledRequests == [1])
        #expect(results.isEmpty)
    }

    @Test
    func synchronousCompletionLeavesNoPendingRequestToCancel() {
        let requester = DataRequesterStub(synchronousResponse: response(hasData: true))
        let provider = PhotoKitAvailabilityProvider(requester: requester)
        var results: [PhotoAvailability] = []

        let token = provider.checkAvailability(of: makePhoto("cached")) { results.append($0) }
        provider.cancel(token)
        requester.complete(1, with: response(isInCloud: true))

        #expect(results == [.local])
        #expect(requester.cancelledRequests.isEmpty)
    }

    @Test
    func duplicateCallbacksCompleteOnlyOnce() {
        let requester = DataRequesterStub()
        let provider = PhotoKitAvailabilityProvider(requester: requester)
        var results: [PhotoAvailability] = []
        let token = provider.checkAvailability(of: makePhoto("duplicate")) { results.append($0) }

        requester.complete(1, with: response(hasData: true))
        requester.complete(1, with: response(isInCloud: true))
        provider.cancel(token)

        #expect(results == [.local])
        #expect(requester.cancelledRequests.isEmpty)
    }

    @Test
    func timeoutCancelsTheUnderlyingRequestAndIgnoresItsLateResponse() async {
        let requester = DataRequesterStub()
        let provider = PhotoKitAvailabilityProvider(requester: requester, timeout: .zero)
        var results: [PhotoAvailability] = []

        let result: PhotoAvailability = await withCheckedContinuation { continuation in
            _ = provider.checkAvailability(of: makePhoto("unresponsive")) { result in
                results.append(result)
                // Keep a duplicate callback observable without resuming a continuation twice.
                if results.count == 1 { continuation.resume(returning: result) }
            }
        }
        requester.complete(1, with: response(hasData: true))

        #expect(result == .unavailable)
        #expect(results == [.unavailable])
        #expect(requester.cancelledRequests == [1])
        withExtendedLifetime(provider) { }
    }

    private func expectAvailability(
        _ expected: PhotoAvailability,
        from response: PhotoDataResponse,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let requester = DataRequesterStub()
        let provider = PhotoKitAvailabilityProvider(requester: requester)
        var results: [PhotoAvailability] = []
        let token = provider.checkAvailability(of: makePhoto("candidate")) { results.append($0) }

        requester.complete(1, with: response)
        provider.cancel(token)

        #expect(results == [expected], sourceLocation: sourceLocation)
        #expect(requester.cancelledRequests.isEmpty, sourceLocation: sourceLocation)
    }

    private func response(
        hasData: Bool = false,
        isDegraded: Bool = false,
        isInCloud: Bool = false,
        isCancelled: Bool = false,
        hasError: Bool = false,
        needsNetwork: Bool = false
    ) -> PhotoDataResponse {
        PhotoDataResponse(
            hasData: hasData,
            isDegraded: isDegraded,
            isInCloud: isInCloud,
            isCancelled: isCancelled,
            hasError: hasError,
            needsNetwork: needsNetwork
        )
    }

    private func makePhoto(_ id: String) -> LibraryPhoto {
        LibraryPhoto(
            id: id, creationDate: nil, modificationDate: nil,
            pixelWidth: 1_200, pixelHeight: 800
        )
    }
}

@MainActor
private final class DataRequesterStub: PhotoDataRequesting {
    struct Request {
        let id: PHImageRequestID
        let photo: LibraryPhoto
        let options: PHImageRequestOptions
        let completion: @MainActor (PhotoDataResponse) -> Void
    }

    private(set) var requests: [Request] = []
    private(set) var cancelledRequests: [PHImageRequestID] = []
    private let synchronousResponse: PhotoDataResponse?

    init(synchronousResponse: PhotoDataResponse? = nil) {
        self.synchronousResponse = synchronousResponse
    }

    func requestData(
        for photo: LibraryPhoto,
        options: PHImageRequestOptions,
        completion: @escaping @MainActor (PhotoDataResponse) -> Void
    ) -> PHImageRequestID {
        let id = PHImageRequestID(requests.count + 1)
        requests.append(Request(id: id, photo: photo, options: options, completion: completion))
        if let synchronousResponse { completion(synchronousResponse) }
        return id
    }

    func cancelRequest(_ requestID: PHImageRequestID) {
        cancelledRequests.append(requestID)
    }

    func complete(_ requestID: PHImageRequestID, with response: PhotoDataResponse) {
        // Retain callbacks to simulate late and duplicate PhotoKit responses.
        requests.first(where: { $0.id == requestID })?.completion(response)
    }
}
