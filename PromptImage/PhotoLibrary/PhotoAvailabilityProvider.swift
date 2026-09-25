import Foundation
import Photos

nonisolated enum PhotoAvailability: Sendable, Equatable {
    case local
    case requiresDownload
    case unavailable
}

@MainActor
protocol PhotoAvailabilityProviding {
    func checkAvailability(
        of photo: LibraryPhoto,
        completion: @escaping @MainActor (PhotoAvailability) -> Void
    ) -> UUID
    func cancel(_ requestID: UUID)
}

nonisolated struct PhotoDataResponse: Sendable {
    let hasData: Bool
    let isDegraded: Bool
    let isInCloud: Bool
    let isCancelled: Bool
    let hasError: Bool
    let needsNetwork: Bool

    var availability: PhotoAvailability {
        if isCancelled || isDegraded { return .unavailable }
        if needsNetwork { return .requiresDownload }
        if hasError { return .unavailable }
        if hasData { return .local }
        return isInCloud ? .requiresDownload : .unavailable
    }
}

@MainActor
protocol PhotoDataRequesting {
    func requestData(
        for photo: LibraryPhoto,
        options: PHImageRequestOptions,
        completion: @escaping @MainActor (PhotoDataResponse) -> Void
    ) -> PHImageRequestID
    func cancelRequest(_ requestID: PHImageRequestID)
}

@MainActor
final class PhotoKitDataRequester: PhotoDataRequesting {
    private let manager = PHImageManager()

    func requestData(
        for photo: LibraryPhoto,
        options: PHImageRequestOptions,
        completion: @escaping @MainActor (PhotoDataResponse) -> Void
    ) -> PHImageRequestID {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.id], options: nil).firstObject
        else {
            completion(PhotoDataResponse(
                hasData: false, isDegraded: false, isInCloud: false,
                isCancelled: false, hasError: true, needsNetwork: false
            ))
            return PHInvalidImageRequestID
        }

        return manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
            let error = info?[PHImageErrorKey] as? NSError
            let response = PhotoDataResponse(
                hasData: data?.isEmpty == false,
                isDegraded: (info?[PHImageResultIsDegradedKey] as? Bool) == true,
                isInCloud: (info?[PHImageResultIsInCloudKey] as? Bool) == true,
                isCancelled: (info?[PHImageCancelledKey] as? Bool) == true,
                hasError: error != nil,
                needsNetwork: error?.domain == PHPhotosErrorDomain
                    && error?.code == PHPhotosError.Code.networkAccessRequired.rawValue
            )
            // Only flags cross to the main actor; no source bytes are retained or decoded.
            Task { @MainActor in completion(response) }
        }
    }

    func cancelRequest(_ requestID: PHImageRequestID) {
        manager.cancelImageRequest(requestID)
    }
}

@MainActor
final class PhotoKitAvailabilityProvider: PhotoAvailabilityProviding {
    private struct PendingRequest {
        var imageRequestID: PHImageRequestID?
        var timeoutTask: Task<Void, Never>?
        let completion: @MainActor (PhotoAvailability) -> Void
    }

    private let requester: any PhotoDataRequesting
    private let timeout: Duration
    private var requests: [UUID: PendingRequest] = [:]

    convenience init() {
        self.init(requester: PhotoKitDataRequester())
    }

    init(requester: any PhotoDataRequesting, timeout: Duration = .seconds(30)) {
        self.requester = requester
        self.timeout = timeout
    }

    func checkAvailability(
        of photo: LibraryPhoto,
        completion: @escaping @MainActor (PhotoAvailability) -> Void
    ) -> UUID {
        let token = UUID()
        requests[token] = PendingRequest(completion: completion)
        let options = PHImageRequestOptions()
        options.version = .current
        options.isSynchronous = false
        options.isNetworkAccessAllowed = false

        let requestID = requester.requestData(for: photo, options: options) { [weak self] response in
            self?.finish(token, result: response.availability)
        }
        if requests[token] != nil {
            requests[token]?.imageRequestID = requestID
            let timeout = timeout
            requests[token]?.timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self?.finish(token, result: .unavailable, cancelUnderlyingRequest: true)
            }
        }
        return token
    }

    func cancel(_ requestID: UUID) {
        guard let request = requests.removeValue(forKey: requestID) else { return }
        request.timeoutTask?.cancel()
        if let identifier = request.imageRequestID {
            requester.cancelRequest(identifier)
        }
    }

    private func finish(
        _ token: UUID,
        result: PhotoAvailability,
        cancelUnderlyingRequest: Bool = false
    ) {
        guard let request = requests.removeValue(forKey: token) else { return }
        request.timeoutTask?.cancel()
        if cancelUnderlyingRequest, let identifier = request.imageRequestID {
            requester.cancelRequest(identifier)
        }
        request.completion(result)
    }
}
