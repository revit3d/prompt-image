import Foundation
import ImageIO
import Photos

nonisolated struct PhotoOCRSource: Sendable {
    static let maximumEncodedBytes = 64 * 1_024 * 1_024

    let data: Data
    let orientation: CGImagePropertyOrientation
}

nonisolated enum PhotoOCRSourceResult: Sendable {
    case source(PhotoOCRSource)
    case requiresDownload
    case unavailable
}

@MainActor
protocol PhotoOCRSourceProviding {
    func requestSource(
        for photo: LibraryPhoto,
        completion: @escaping @MainActor (PhotoOCRSourceResult) -> Void
    ) -> UUID
    func cancel(_ requestID: UUID)
}

nonisolated struct PhotoOCRDataResponse: Sendable {
    let data: Data?
    let orientation: CGImagePropertyOrientation
    let flags: PhotoDataResponse
}

@MainActor
protocol PhotoOCRDataRequesting {
    func isCurrentAndAccessible(_ photo: LibraryPhoto) -> Bool
    func requestData(
        for photo: LibraryPhoto,
        options: PHImageRequestOptions,
        completion: @escaping @MainActor (PhotoOCRDataResponse) -> Void
    ) -> PHImageRequestID
    func cancelRequest(_ requestID: PHImageRequestID)
}

@MainActor
final class PhotoKitOCRDataRequester: PhotoOCRDataRequesting {
    private let manager = PHImageManager()

    func isCurrentAndAccessible(_ photo: LibraryPhoto) -> Bool {
        currentAsset(for: photo) != nil
    }

    func requestData(
        for photo: LibraryPhoto,
        options: PHImageRequestOptions,
        completion: @escaping @MainActor (PhotoOCRDataResponse) -> Void
    ) -> PHImageRequestID {
        guard let asset = currentAsset(for: photo) else {
            completion(PhotoOCRDataResponse(
                data: nil,
                orientation: .up,
                flags: PhotoDataResponse(
                    hasData: false, isDegraded: false, isInCloud: false,
                    isCancelled: false, hasError: true, needsNetwork: false
                )
            ))
            return PHInvalidImageRequestID
        }

        return manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, orientation, info in
            let error = info?[PHImageErrorKey] as? NSError
            let flags = PhotoDataResponse(
                hasData: data?.isEmpty == false,
                isDegraded: (info?[PHImageResultIsDegradedKey] as? Bool) == true,
                isInCloud: (info?[PHImageResultIsInCloudKey] as? Bool) == true,
                isCancelled: (info?[PHImageCancelledKey] as? Bool) == true,
                hasError: error != nil,
                needsNetwork: error?.domain == PHPhotosErrorDomain
                    && error?.code == PHPhotosError.Code.networkAccessRequired.rawValue
            )
            // PhotoKit has already materialized the compressed bytes. Drop oversized
            // responses here rather than retaining them across the actor hop.
            let boundedData = data.flatMap {
                $0.count <= PhotoOCRSource.maximumEncodedBytes ? $0 : nil
            }
            let response = PhotoOCRDataResponse(data: boundedData, orientation: orientation, flags: flags)
            Task { @MainActor in completion(response) }
        }
    }

    func cancelRequest(_ requestID: PHImageRequestID) {
        manager.cancelImageRequest(requestID)
    }

    private func currentAsset(for photo: LibraryPhoto) -> PHAsset? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.id], options: nil).firstObject,
              asset.mediaType == .image, !asset.isHidden,
              asset.creationDate == photo.creationDate,
              asset.modificationDate == photo.modificationDate,
              asset.pixelWidth == photo.pixelWidth,
              asset.pixelHeight == photo.pixelHeight
        else { return nil }
        return asset
    }
}

@MainActor
final class PhotoKitOCRSourceProvider: PhotoOCRSourceProviding {
    private struct PendingRequest {
        let photo: LibraryPhoto
        var imageRequestID: PHImageRequestID?
        var timeoutTask: Task<Void, Never>?
        let completion: @MainActor (PhotoOCRSourceResult) -> Void
    }

    private let requester: any PhotoOCRDataRequesting
    private let timeout: Duration
    private var requests: [UUID: PendingRequest] = [:]

    convenience init() {
        self.init(requester: PhotoKitOCRDataRequester())
    }

    init(requester: any PhotoOCRDataRequesting, timeout: Duration = .seconds(30)) {
        self.requester = requester
        self.timeout = timeout
    }

    isolated deinit {
        for request in requests.values {
            request.timeoutTask?.cancel()
            if let identifier = request.imageRequestID { requester.cancelRequest(identifier) }
        }
    }

    func requestSource(
        for photo: LibraryPhoto,
        completion: @escaping @MainActor (PhotoOCRSourceResult) -> Void
    ) -> UUID {
        let token = UUID()
        guard requester.isCurrentAndAccessible(photo) else {
            completion(.unavailable)
            return token
        }

        requests[token] = PendingRequest(photo: photo, completion: completion)
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        options.isNetworkAccessAllowed = false

        let identifier = requester.requestData(for: photo, options: options) { [weak self] response in
            self?.receive(response, token: token)
        }
        // A requester can complete synchronously before returning its identifier.
        if requests[token] != nil {
            requests[token]?.imageRequestID = identifier
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
        if let identifier = request.imageRequestID { requester.cancelRequest(identifier) }
    }

    private func receive(_ response: PhotoOCRDataResponse, token: UUID) {
        guard requests[token] != nil else { return }
        let result: PhotoOCRSourceResult
        switch response.flags.availability {
        case .local:
            if let data = response.data, !data.isEmpty, data.count <= PhotoOCRSource.maximumEncodedBytes {
                result = .source(PhotoOCRSource(data: data, orientation: response.orientation))
            } else {
                result = .unavailable
            }
        case .requiresDownload:
            result = .requiresDownload
        case .unavailable:
            result = .unavailable
        }
        finish(token, result: result)
    }

    private func finish(
        _ token: UUID,
        result: PhotoOCRSourceResult,
        cancelUnderlyingRequest: Bool = false
    ) {
        guard let request = requests.removeValue(forKey: token) else { return }
        request.timeoutTask?.cancel()
        if cancelUnderlyingRequest, let identifier = request.imageRequestID {
            requester.cancelRequest(identifier)
        }
        // Permission and selection may have changed while PhotoKit produced data.
        // Never publish a different asset version under the requested snapshot.
        request.completion(requester.isCurrentAndAccessible(request.photo) ? result : .unavailable)
    }
}
