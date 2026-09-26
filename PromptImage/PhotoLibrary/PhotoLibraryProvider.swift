import Foundation
import Photos

@MainActor
protocol PhotoLibraryProviding {
    func photos() async -> [LibraryPhoto]
    func startObserving(_ onChange: @escaping @MainActor @Sendable (PhotoLibraryChange) -> Void)
    func stopObserving()
}

@MainActor
final class PhotoKitLibraryProvider: NSObject, PhotoLibraryProviding, PHPhotoLibraryChangeObserver {
    private var onChange: (@MainActor @Sendable (PhotoLibraryChange) -> Void)?
    private var baseline = PhotoLibraryFetchBaseline<PHFetchResult<PHAsset>>()

    func photos() async -> [LibraryPhoto] {
        let generation = baseline.beginFetch()
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
            return PhotoLibraryFetch(assets: assets, photos: photos)
        }

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if !Task.isCancelled {
            baseline.adoptFetch(result.assets, generation: generation)
        }
        return result.photos
    }

    func startObserving(_ onChange: @escaping @MainActor @Sendable (PhotoLibraryChange) -> Void) {
        let wasObserving = self.onChange != nil
        self.onChange = onChange
        if !wasObserving {
            PHPhotoLibrary.shared().register(self)
        }
    }

    func stopObserving() {
        baseline.reset()
        guard onChange != nil else { return }
        onChange = nil
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        // PHChange and PHFetchResult are Sendable in the supported Photos SDK.
        // All baseline mutation stays serialized on the main actor.
        Task { @MainActor [weak self] in
            self?.receive(changeInstance)
        }
    }

    private func receive(_ change: PHChange) {
        guard let onChange else { return }
        guard let before = baseline.value else {
            baseline.recordChange()
            onChange(PhotoLibraryChange(requiresFullReindex: true))
            return
        }
        guard let details = change.changeDetails(for: before) else {
            baseline.recordChange()
            // Unrelated notifications can still accompany limited-access
            // changes. Always fetch the current permitted metadata snapshot.
            onChange(PhotoLibraryChange())
            return
        }
        baseline.recordChange(details.fetchResultAfterChanges)
        guard details.hasIncrementalChanges else {
            onChange(PhotoLibraryChange(requiresFullReindex: true))
            return
        }

        let changedIDs = Set(details.changedObjects.map(\.localIdentifier))
        var contentChangedIDs = Set(details.removedObjects.map(\.localIdentifier))
        // changedObjects describes the after state. Ask for object-level change
        // details using the matching object from the before snapshot instead.
        var unresolvedIDs = changedIDs
        before.enumerateObjects { asset, _, stop in
            guard !unresolvedIDs.isEmpty else {
                stop.pointee = true
                return
            }
            guard unresolvedIDs.remove(asset.localIdentifier) != nil else { return }
            if let objectChange = change.changeDetails(for: asset) {
                if objectChange.assetContentChanged || objectChange.objectWasDeleted {
                    contentChangedIDs.insert(asset.localIdentifier)
                }
            } else {
                // Incomplete change details cannot establish that old features
                // remain valid, so conservatively invalidate this asset only.
                contentChangedIDs.insert(asset.localIdentifier)
            }
        }
        contentChangedIDs.formUnion(unresolvedIDs)
        onChange(PhotoLibraryChange(contentChangedIDs: contentChangedIDs))
    }
}

nonisolated private struct PhotoLibraryFetch: Sendable {
    let assets: PHFetchResult<PHAsset>
    let photos: [LibraryPhoto]
}
