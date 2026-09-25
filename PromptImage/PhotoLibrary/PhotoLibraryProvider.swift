import Foundation
import Photos

@MainActor
protocol PhotoLibraryProviding {
    func photos() async -> [LibraryPhoto]
    func startObserving(_ onChange: @escaping @MainActor @Sendable () -> Void)
    func stopObserving()
}

@MainActor
final class PhotoKitLibraryProvider: NSObject, PhotoLibraryProviding, PHPhotoLibraryChangeObserver {
    private var onChange: (@MainActor @Sendable () -> Void)?

    func photos() async -> [LibraryPhoto] {
        let task = Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.includeHiddenAssets = false
            let assets = PHAsset.fetchAssets(with: .image, options: options)
            var photos: [LibraryPhoto] = []
            photos.reserveCapacity(assets.count)

            assets.enumerateObjects { asset, _, stop in
                guard !Task.isCancelled else {
                    stop.pointee = true
                    return
                }
                photos.append(LibraryPhoto(
                    id: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    modificationDate: asset.modificationDate,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight
                ))
            }
            return photos
        }

        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func startObserving(_ onChange: @escaping @MainActor @Sendable () -> Void) {
        let wasObserving = self.onChange != nil
        self.onChange = onChange
        if !wasObserving {
            PHPhotoLibrary.shared().register(self)
        }
    }

    func stopObserving() {
        guard onChange != nil else { return }
        onChange = nil
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        // PhotoKit delivers changes on its own serial queue. A fresh fetch also
        // catches limited-library changes without moving PHChange between actors.
        Task { @MainActor [weak self] in
            self?.onChange?()
        }
    }
}
