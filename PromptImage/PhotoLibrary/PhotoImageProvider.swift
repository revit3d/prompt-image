import Photos
import UIKit

enum PhotoImageResult {
    case image(UIImage)
    case cloudOnly
    case unavailable
}

@MainActor
protocol PhotoImageProviding {
    func requestImage(
        for photo: LibraryPhoto,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        completion: @escaping @MainActor (PhotoImageResult) -> Void
    ) -> PHImageRequestID
    func cancelRequest(_ requestID: PHImageRequestID)
    func cancelAll()
}

@MainActor
final class PhotoKitImageProvider: PhotoImageProviding {
    private let manager = PHCachingImageManager()
    private var requests: [UUID: PHImageRequestID] = [:]

    func requestImage(
        for photo: LibraryPhoto,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        completion: @escaping @MainActor (PhotoImageResult) -> Void
    ) -> PHImageRequestID {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.id], options: nil).firstObject
        else {
            completion(.unavailable)
            return PHInvalidImageRequestID
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.version = .current

        let token = UUID()
        let requestID = manager.requestImage(
            for: asset, targetSize: targetSize, contentMode: contentMode, options: options
        ) { [weak self] image, info in
            let isCancelled = (info?[PHImageCancelledKey] as? Bool) == true
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true

            // Even a synchronous PhotoKit callback is delivered after request registration.
            Task { @MainActor [weak self] in
                guard !isDegraded, let self,
                      self.requests.removeValue(forKey: token) != nil else { return }
                if isCancelled {
                    completion(.unavailable)
                } else if let image {
                    completion(.image(image))
                } else if isInCloud {
                    completion(.cloudOnly)
                } else {
                    completion(.unavailable)
                }
            }
        }
        requests[token] = requestID
        return requestID
    }

    func cancelRequest(_ requestID: PHImageRequestID) {
        guard let token = requests.first(where: { $0.value == requestID })?.key else { return }
        requests.removeValue(forKey: token)
        manager.cancelImageRequest(requestID)
    }

    func cancelAll() {
        let pending = Array(requests.values)
        requests.removeAll()
        for requestID in pending {
            manager.cancelImageRequest(requestID)
        }
        manager.stopCachingImagesForAllAssets()
    }
}
