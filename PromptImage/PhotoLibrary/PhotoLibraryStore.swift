import Observation
import Photos

@MainActor
@Observable
final class PhotoLibraryStore {
    let access: PhotoLibraryAccess
    let images: any PhotoImageProviding
    let availability: PhotoAvailabilityScan
    private(set) var photos: [LibraryPhoto] = []
    private(set) var isLoading = false
    var selectedPhoto: LibraryPhoto?

    @ObservationIgnored private let provider: any PhotoLibraryProviding
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var lastAuthorization: PHAuthorizationStatus

    convenience init() {
        self.init(
            access: PhotoLibraryAccess(),
            provider: PhotoKitLibraryProvider(),
            images: PhotoKitImageProvider()
        )
    }

    init(
        access: PhotoLibraryAccess,
        provider: any PhotoLibraryProviding,
        images: any PhotoImageProviding,
        availability: PhotoAvailabilityScan? = nil
    ) {
        self.access = access
        self.provider = provider
        self.images = images
        self.availability = availability ?? PhotoAvailabilityScan()
        lastAuthorization = access.status
    }

    isolated deinit {
        fetchTask?.cancel()
        provider.stopObserving()
        availability.pause()
    }

    func refresh() {
        refreshAuthorization()
        guard canReadPhotos else {
            clearLibrary()
            return
        }

        if !isObserving {
            isObserving = true
            provider.startObserving { [weak self] in
                self?.refresh()
            }
        }

        guard fetchTask == nil else {
            needsRefresh = true
            return
        }
        fetchPhotos()
    }

    private var canReadPhotos: Bool {
        access.status == .authorized || access.status == .limited
    }

    private func refreshAuthorization() {
        access.refresh()
        if lastAuthorization == .authorized && access.status == .limited {
            // The previously displayed library may include photos that were
            // removed from access. Clear it before fetching the new selection.
            photos = []
            selectedPhoto = nil
            images.cancelAll()
            availability.clear()
        }
        lastAuthorization = access.status
    }

    private func fetchPhotos() {
        isLoading = true
        needsRefresh = false
        generation += 1
        let requestGeneration = generation
        let requestAuthorization = access.status
        let provider = provider
        fetchTask = Task { [weak self] in
            let photos = await provider.photos()
            guard !Task.isCancelled else { return }
            self?.didFetch(photos, generation: requestGeneration, authorization: requestAuthorization)
        }
    }

    private func didFetch(
        _ newPhotos: [LibraryPhoto],
        generation requestGeneration: Int,
        authorization requestAuthorization: PHAuthorizationStatus
    ) {
        guard generation == requestGeneration else { return }
        fetchTask = nil
        refreshAuthorization()
        guard canReadPhotos else {
            clearLibrary()
            return
        }

        if needsRefresh || access.status != requestAuthorization {
            // Do not publish a fetch superseded by a library or access change.
            fetchPhotos()
            return
        }

        photos = newPhotos
        availability.updatePhotos(newPhotos)
        if let selectedPhoto {
            self.selectedPhoto = newPhotos.first { $0.id == selectedPhoto.id }
        }
        isLoading = false
    }

    private func clearLibrary() {
        generation += 1
        fetchTask?.cancel()
        fetchTask = nil
        needsRefresh = false
        isLoading = false
        photos = []
        selectedPhoto = nil
        if isObserving {
            provider.stopObserving()
            isObserving = false
        }
        images.cancelAll()
        availability.clear()
    }
}
