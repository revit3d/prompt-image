import Observation
import Photos

@MainActor
protocol PhotoLibraryAuthorizing {
    func authorizationStatus() -> PHAuthorizationStatus
    func requestAuthorization() async -> PHAuthorizationStatus
}

@MainActor
struct PhotoKitAuthorizationProvider: PhotoLibraryAuthorizing {
    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        // PhotoKit has no read-only level. Reading existing photos requires readWrite.
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }
}

@MainActor
@Observable
final class PhotoLibraryAccess {
    private(set) var status: PHAuthorizationStatus
    private(set) var isRequesting = false

    private let provider: any PhotoLibraryAuthorizing

    convenience init() {
        self.init(provider: PhotoKitAuthorizationProvider())
    }

    init(provider: any PhotoLibraryAuthorizing) {
        self.provider = provider
        status = provider.authorizationStatus()
    }

    func refresh() {
        status = provider.authorizationStatus()
    }

    func requestAccess() async {
        guard !isRequesting else { return }

        refresh()
        guard status == .notDetermined else { return }

        isRequesting = true
        defer { isRequesting = false }
        status = await provider.requestAuthorization()
    }
}
