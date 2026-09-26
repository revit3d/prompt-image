import Foundation
import ImageIO
import Photos
import Testing
@testable import PromptImage

@MainActor
struct PhotoOCRSourceProviderTests {
    @Test
    func requestsCurrentFullQualityDataWithoutNetworkAccess() {
        let requester = OCRDataRequesterStub()
        let provider = PhotoKitOCRSourceProvider(requester: requester)
        let token = provider.requestSource(for: requester.photo) { _ in }

        #expect(requester.requests.count == 1)
        #expect(requester.requests.first?.photo == requester.photo)
        #expect(requester.requests.first?.options.version == .current)
        #expect(requester.requests.first?.options.deliveryMode == .highQualityFormat)
        #expect(requester.requests.first?.options.isNetworkAccessAllowed == false)
        #expect(requester.requests.first?.options.isSynchronous == false)
        provider.cancel(token)
    }

    @Test(arguments: [true, false])
    func returnsLocalSourceBytesAndPhotoKitOrientationEvenWithCloudCopy(isInCloud: Bool) {
        let requester = OCRDataRequesterStub()
        let provider = PhotoKitOCRSourceProvider(requester: requester)
        let bytes = Data([1, 2, 3, 4])
        var result: PhotoOCRSourceResult?
        _ = provider.requestSource(for: requester.photo) { result = $0 }

        requester.complete(1, with: response(data: bytes, orientation: .rightMirrored, isInCloud: isInCloud))

        guard case .source(let source) = result else {
            Issue.record("Expected usable local image data.")
            return
        }
        #expect(source.data == bytes)
        #expect(source.orientation == .rightMirrored)
        #expect(requester.validationCount == 2)
    }

    @Test
    func missingCloudSourceRequiresDownload() {
        expectResult(.requiresDownload, from: response(data: nil, isInCloud: true))
    }

    @Test(arguments: [true, false])
    func networkRequiredErrorDoesNotDependOnCloudFlag(isInCloud: Bool) {
        expectResult(.requiresDownload, from: response(
            data: nil, isInCloud: isInCloud, hasError: true, needsNetwork: true
        ))
    }

    @Test(arguments: [true, false])
    func errorsDoNotPublishSourceEvenWhenDataExists(isInCloud: Bool) {
        expectResult(.unavailable, from: response(isInCloud: isInCloud, hasError: true))
    }

    @Test(arguments: [true, false])
    func degradedAndCancelledDataNeverReachesRecognition(isDegraded: Bool) {
        expectResult(.unavailable, from: response(
            isDegraded: isDegraded, isInCloud: true, isCancelled: !isDegraded
        ))
    }

    @Test
    func nilAndEmptySourceAreUnavailable() {
        expectResult(.unavailable, from: response(data: nil))
        expectResult(.unavailable, from: response(data: Data()))
    }

    @Test
    func sourceBytesAreRequiredEvenWhenMetadataClaimsDataExists() {
        let flags = PhotoDataResponse(
            hasData: true, isDegraded: false, isInCloud: true,
            isCancelled: false, hasError: false, needsNetwork: false
        )
        expectResult(.unavailable, from: PhotoOCRDataResponse(data: nil, orientation: .up, flags: flags))
        expectResult(.unavailable, from: PhotoOCRDataResponse(data: Data(), orientation: .up, flags: flags))
    }

    @Test
    func encodedSizeLimitRejectsOversizedDataAndAcceptsTheBoundary() {
        let limit = PhotoOCRSource.maximumEncodedBytes
        #expect(limit == 64 * 1_024 * 1_024)
        expectResult(.unavailable, from: response(data: Data(repeating: 0, count: limit + 1)))
        expectResult(.source, from: response(data: Data(repeating: 0, count: limit)))
    }

    @Test(arguments: [true, false])
    func missingAccessOrSelectionDoesNotStartADataRequest(revoked: Bool) {
        let requester = OCRDataRequesterStub()
        requester.hasAccess = !revoked
        requester.isSelected = revoked
        let provider = PhotoKitOCRSourceProvider(requester: requester)
        var results: [SourceOutcome] = []

        let token = provider.requestSource(for: requester.photo) { results.append(outcome($0)) }
        provider.cancel(token)

        #expect(results == [.unavailable])
        #expect(requester.requests.isEmpty)
        #expect(requester.cancelledRequests.isEmpty)
    }

    @Test(arguments: [true, false])
    func revocationOrSelectionRemovalDuringTheRequestRejectsDeliveredData(revoked: Bool) {
        let requester = OCRDataRequesterStub()
        let provider = PhotoKitOCRSourceProvider(requester: requester)
        var results: [SourceOutcome] = []
        _ = provider.requestSource(for: requester.photo) { results.append(outcome($0)) }

        requester.hasAccess = !revoked
        requester.isSelected = revoked
        requester.complete(1, with: response())

        #expect(results == [.unavailable])
        #expect(requester.validationCount == 2)
    }

    @Test(arguments: [SnapshotChange.creationDate, .modificationDate, .dimensions])
    func changedSnapshotDoesNotStartADataRequest(change: SnapshotChange) {
        let requester = OCRDataRequesterStub()
        let original = requester.photo
        requester.photo = changed(original, change: change)
        let provider = PhotoKitOCRSourceProvider(requester: requester)
        var results: [SourceOutcome] = []

        _ = provider.requestSource(for: original) { results.append(outcome($0)) }

        #expect(results == [.unavailable])
        #expect(requester.requests.isEmpty)
    }

    @Test(arguments: [SnapshotChange.creationDate, .modificationDate, .dimensions])
    func changedSnapshotRejectsDeliveredData(change: SnapshotChange) {
        let requester = OCRDataRequesterStub()
        let provider = PhotoKitOCRSourceProvider(requester: requester)
        var results: [SourceOutcome] = []
        _ = provider.requestSource(for: requester.photo) { results.append(outcome($0)) }

        requester.photo = changed(requester.photo, change: change)
        requester.complete(1, with: response())

        #expect(results == [.unavailable])
        #expect(requester.validationCount == 2)
    }

    @Test
    func revokedAccessAlsoSuppressesStaleDownloadStatus() {
        let requester = OCRDataRequesterStub()
        let provider = PhotoKitOCRSourceProvider(requester: requester)
        var results: [SourceOutcome] = []
        _ = provider.requestSource(for: requester.photo) { results.append(outcome($0)) }
        requester.hasAccess = false

        requester.complete(1, with: response(data: nil, isInCloud: true))

        #expect(results == [.unavailable])
    }

    @Test
    func cancellationStopsTheRequestOnceAndSuppressesLateCallbacks() {
        let requester = OCRDataRequesterStub()
        let provider = PhotoKitOCRSourceProvider(requester: requester)
        var results: [SourceOutcome] = []
        let token = provider.requestSource(for: requester.photo) { results.append(outcome($0)) }

        provider.cancel(token)
        provider.cancel(token)
        requester.complete(1, with: response(isCancelled: true))
        requester.complete(1, with: response())

        #expect(results.isEmpty)
        #expect(requester.cancelledRequests == [1])
        #expect(requester.validationCount == 1)
    }

    @Test
    func synchronousCompletionLeavesNoPhantomRequestAndIgnoresDuplicates() {
        let requester = OCRDataRequesterStub()
        requester.synchronousResponse = response()
        let provider = PhotoKitOCRSourceProvider(requester: requester)
        var results: [SourceOutcome] = []

        let token = provider.requestSource(for: requester.photo) { results.append(outcome($0)) }
        provider.cancel(token)
        requester.complete(1, with: response(data: nil, isInCloud: true))

        #expect(results == [.source])
        #expect(requester.cancelledRequests.isEmpty)
        #expect(requester.validationCount == 2)
    }

    @Test
    func duplicateCallbacksCompleteOnlyOnce() {
        let requester = OCRDataRequesterStub()
        let provider = PhotoKitOCRSourceProvider(requester: requester)
        var results: [SourceOutcome] = []
        let token = provider.requestSource(for: requester.photo) { results.append(outcome($0)) }

        requester.complete(1, with: response())
        requester.complete(1, with: response(data: nil, isInCloud: true))
        provider.cancel(token)

        #expect(results == [.source])
        #expect(requester.cancelledRequests.isEmpty)
        #expect(requester.validationCount == 2)
    }

    @Test
    func timeoutCancelsTheUnderlyingRequestAndSuppressesLateData() async {
        let requester = OCRDataRequesterStub()
        let provider = PhotoKitOCRSourceProvider(requester: requester, timeout: .zero)
        var results: [SourceOutcome] = []

        await withCheckedContinuation { continuation in
            _ = provider.requestSource(for: requester.photo) { result in
                results.append(outcome(result))
                if results.count == 1 { continuation.resume() }
            }
        }
        requester.complete(1, with: response())

        #expect(results == [.unavailable])
        #expect(requester.cancelledRequests == [1])
        withExtendedLifetime(provider) { }
    }

    @Test
    func deinitializationCancelsOutstandingRequests() {
        let requester = OCRDataRequesterStub()
        var provider: PhotoKitOCRSourceProvider? = PhotoKitOCRSourceProvider(requester: requester)
        var results: [SourceOutcome] = []
        _ = provider?.requestSource(for: requester.photo) { results.append(outcome($0)) }

        provider = nil
        requester.complete(1, with: response())

        #expect(requester.cancelledRequests == [1])
        #expect(results.isEmpty)
    }

    private func expectResult(
        _ expected: SourceOutcome,
        from response: PhotoOCRDataResponse,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let requester = OCRDataRequesterStub()
        let provider = PhotoKitOCRSourceProvider(requester: requester)
        var results: [SourceOutcome] = []
        let token = provider.requestSource(for: requester.photo) { results.append(outcome($0)) }

        requester.complete(1, with: response)
        provider.cancel(token)

        #expect(results == [expected], sourceLocation: sourceLocation)
        #expect(requester.cancelledRequests.isEmpty, sourceLocation: sourceLocation)
    }

    private func changed(_ photo: LibraryPhoto, change: SnapshotChange) -> LibraryPhoto {
        LibraryPhoto(
            id: photo.id,
            creationDate: change == .creationDate ? Date(timeIntervalSince1970: 100) : photo.creationDate,
            modificationDate: change == .modificationDate ? Date(timeIntervalSince1970: 200) : photo.modificationDate,
            pixelWidth: change == .dimensions ? photo.pixelWidth + 1 : photo.pixelWidth,
            pixelHeight: photo.pixelHeight
        )
    }

    private func response(
        data: Data? = Data([1, 2, 3]),
        orientation: CGImagePropertyOrientation = .up,
        isDegraded: Bool = false,
        isInCloud: Bool = false,
        isCancelled: Bool = false,
        hasError: Bool = false,
        needsNetwork: Bool = false
    ) -> PhotoOCRDataResponse {
        PhotoOCRDataResponse(data: data, orientation: orientation, flags: PhotoDataResponse(
            hasData: data?.isEmpty == false,
            isDegraded: isDegraded,
            isInCloud: isInCloud,
            isCancelled: isCancelled,
            hasError: hasError,
            needsNetwork: needsNetwork
        ))
    }

    enum SnapshotChange: Sendable, Equatable { case creationDate, modificationDate, dimensions }
}

private enum SourceOutcome: Equatable { case source, requiresDownload, unavailable }

private func outcome(_ result: PhotoOCRSourceResult) -> SourceOutcome {
    switch result {
    case .source: .source
    case .requiresDownload: .requiresDownload
    case .unavailable: .unavailable
    }
}

@MainActor
private final class OCRDataRequesterStub: PhotoOCRDataRequesting {
    struct Request {
        let id: PHImageRequestID
        let photo: LibraryPhoto
        let options: PHImageRequestOptions
        let completion: @MainActor (PhotoOCRDataResponse) -> Void
    }

    var photo = LibraryPhoto(
        id: "selected", creationDate: nil, modificationDate: nil,
        pixelWidth: 1_200, pixelHeight: 800
    )
    var hasAccess = true
    var isSelected = true
    var synchronousResponse: PhotoOCRDataResponse?
    private(set) var validationCount = 0
    private(set) var requests: [Request] = []
    private(set) var cancelledRequests: [PHImageRequestID] = []

    func isCurrentAndAccessible(_ photo: LibraryPhoto) -> Bool {
        validationCount += 1
        return hasAccess && isSelected && self.photo == photo
    }

    func requestData(
        for photo: LibraryPhoto,
        options: PHImageRequestOptions,
        completion: @escaping @MainActor (PhotoOCRDataResponse) -> Void
    ) -> PHImageRequestID {
        let id = PHImageRequestID(requests.count + 1)
        requests.append(Request(id: id, photo: photo, options: options, completion: completion))
        if let synchronousResponse { completion(synchronousResponse) }
        return id
    }

    func cancelRequest(_ requestID: PHImageRequestID) {
        cancelledRequests.append(requestID)
    }

    func complete(_ requestID: PHImageRequestID, with response: PhotoOCRDataResponse) {
        // Keep callbacks to simulate PhotoKit's late and duplicate delivery.
        requests.first(where: { $0.id == requestID })?.completion(response)
    }
}
