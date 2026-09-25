import Observation
import Photos
import UIKit

@MainActor
@Observable
final class PhotoImageLoader {
    private(set) var result: PhotoImageResult?
    private let provider: any PhotoImageProviding
    private var requestID: PHImageRequestID?
    private var generation = 0
    private var isPending = false

    init(provider: any PhotoImageProviding) {
        self.provider = provider
    }

    func load(photo: LibraryPhoto, targetSize: CGSize, contentMode: PHImageContentMode) {
        cancel()
        let requestedGeneration = generation
        isPending = true
        let identifier = provider.requestImage(
            for: photo, targetSize: targetSize, contentMode: contentMode
        ) { [weak self] result in
            guard let self, self.generation == requestedGeneration else { return }
            self.isPending = false
            self.requestID = nil
            self.result = result
        }
        // A provider may complete before returning its request identifier.
        if isPending {
            requestID = identifier
        }
    }

    func cancel() {
        generation += 1
        isPending = false
        if let requestID {
            provider.cancelRequest(requestID)
        }
        requestID = nil
        result = nil
    }
}
