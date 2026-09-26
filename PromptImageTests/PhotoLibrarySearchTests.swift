import Foundation
import Photos
import Testing
import UIKit
@testable import PromptImage

/// Uses the production library → index → search invalidation wiring and real
/// SQLite retrieval. Synthetic OCR keeps this independent of Photos and models.
@MainActor
struct PhotoLibrarySearchTests {
    @Test
    func refreshingLimitedAccessClearsSearchBeforeReconcilingTheAllowedPhotos() async throws {
        try await withLibrarySearch { fixture in
            try await fixture.searchAndSelect()
            fixture.provider.snapshot = [fixture.photos[1]]
            fixture.library.refresh()

            fixture.expectCleared()
            try await fixture.waitForIndex()
            try await fixture.searchAndSelect(expectedIDs: ["keep"])
            #expect(try await fixture.database.record(for: "changed") == nil)
        }
    }

    @Test
    func contentObserverClearsSearchAndPrunesOCRDespiteUnchangedPhotoMetadata() async throws {
        try await withLibrarySearch { fixture in
            try await fixture.searchAndSelect()
            fixture.provider.onChange?(PhotoLibraryChange(contentChangedIDs: ["changed"]))

            fixture.expectCleared()
            try await fixture.waitForIndex()
            try await fixture.searchAndSelect(expectedIDs: ["keep"])
            #expect(try await fixture.database.record(for: "changed")?.ocr.status == .pending)
        }
    }

    @Test
    func backgroundAndRevocationClearSearchAndRevokedResultsCannotReturnOnReauthorization() async throws {
        try await withLibrarySearch { fixture in
            try await fixture.searchAndSelect()
            fixture.library.setActive(false)
            fixture.expectCleared()
            #expect(!fixture.index.searchState.isReady)

            fixture.library.setActive(true)
            fixture.library.refresh()
            try await fixture.waitForIndex()
            try await fixture.searchAndSelect()

            fixture.authorization.status = .denied
            fixture.library.refresh()
            fixture.expectCleared()
            await fixture.index.waitForIdle()
            await fixture.search.waitForIdle()
            #expect(try await fixture.database.summary().totalCount == 0)

            fixture.authorization.status = .limited
            fixture.provider.snapshot = [fixture.photos[1]]
            fixture.library.refresh()
            try await fixture.waitForIndex()
            fixture.search.activate()
            fixture.search.search()
            await fixture.search.waitForIdle()
            #expect(fixture.search.phase == .emptyIndex)
            fixture.expectCleared()
        }
    }
}

@MainActor
private func withLibrarySearch(_ body: (LibrarySearchFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LibrarySearch-\(UUID())")
    let fixture = try LibrarySearchFixture(directory: directory)
    do {
        try await fixture.prepare()
        try await body(fixture)
        await fixture.finish()
        try FileManager.default.removeItem(at: directory)
    } catch {
        await fixture.finish()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

@MainActor
private final class LibrarySearchFixture {
    let database: PhotoIndexStore
    let authorization = LibrarySearchAuthorization()
    let provider = LibrarySearchProvider()
    let media = LibrarySearchMedia()
    let photos = ["changed", "keep"].map {
        LibraryPhoto(id: $0, creationDate: nil, modificationDate: nil, pixelWidth: 100, pixelHeight: 100)
    }
    lazy var index = PhotoIndexingStore(provider: media, processor: LibrarySearchProcessor(),
        openStore: { [database] in database }, isCurrentAndAccessible: { [weak self] photo in
            guard let self else { return false }
            return (self.authorization.status == .authorized || self.authorization.status == .limited)
                && self.provider.snapshot.contains(photo)
        })
    lazy var library = PhotoLibraryStore(access: PhotoLibraryAccess(provider: authorization),
        provider: provider, images: media, availability: PhotoAvailabilityScan(provider: media), indexing: index)
    var search: PhotoSearchStore { library.search! }

    init(directory: URL) throws { database = try PhotoIndexStore(directoryURL: directory) }

    func prepare() async throws {
        provider.snapshot = photos
        try await database.synchronize(photos, versions: LibrarySearchProcessor.modelVersions)
        for photo in photos {
            let ticket = try await database.beginWork(for: photo.id, stage: .ocr)
            let result = PhotoOCRResult(lines: [PhotoOCRLine(text: "recipe", confidence: 0.9,
                boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))], revision: 3, languages: ["en-US"])
            try await database.saveOCR(result, for: ticket)
        }
        library.setActive(true)
        library.refresh()
        try await waitForIndex()
    }

    func waitForIndex() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if !library.isLoading && !index.isBusy && index.searchState.isReady { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw LibrarySearchError.timedOut
    }

    func searchAndSelect(expectedIDs: Set<String> = ["changed", "keep"]) async throws {
        search.activate()
        search.mode = .textOnly
        search.text = "recipe"
        search.search()
        await search.waitForIdle()
        #expect(search.phase == .results)
        #expect(Set(search.matches.map(\.photo.id)) == expectedIDs)
        let first = try #require(search.matches.first)
        search.select(first.photo)
        #expect(search.selectedPhoto == first.photo)
    }

    func expectCleared() {
        #expect(search.matches.isEmpty)
        #expect(search.selectedPhoto == nil)
    }

    func finish() async {
        library.setActive(false)
        await search.waitForIdle()
        await index.waitForIdle()
        try? await database.close()
    }
}

nonisolated private enum LibrarySearchError: Error { case timedOut, unexpectedInference }

@MainActor
private final class LibrarySearchAuthorization: PhotoLibraryAuthorizing {
    var status = PHAuthorizationStatus.limited
    func authorizationStatus() -> PHAuthorizationStatus { status }
    func requestAuthorization() async -> PHAuthorizationStatus { status }
}

@MainActor
private final class LibrarySearchProvider: PhotoLibraryProviding {
    var snapshot: [LibraryPhoto] = []
    var onChange: (@MainActor @Sendable (PhotoLibraryChange) -> Void)?
    func photos() async -> [LibraryPhoto] { snapshot }
    func startObserving(_ onChange: @escaping @MainActor @Sendable (PhotoLibraryChange) -> Void) {
        self.onChange = onChange
    }
    func stopObserving() { onChange = nil }
}

@MainActor
private final class LibrarySearchProcessor: PhotoIndexProcessing {
    nonisolated static let modelVersions = PhotoIndexVersions(embedding: "library-search-test", ocr: "library-search-ocr")
    @MainActor func versions() async throws -> PhotoIndexVersions { Self.modelVersions }
    @MainActor func embedding(_ source: PhotoOCRSource) async throws -> CLIPEmbedding { throw LibrarySearchError.unexpectedInference }
    @MainActor func recognize(_ source: PhotoOCRSource) async throws -> PhotoOCRResult { throw LibrarySearchError.unexpectedInference }
    @MainActor func unload() async { }
}

@MainActor
private final class LibrarySearchMedia: PhotoImageProviding, PhotoOCRSourceProviding, PhotoAvailabilityProviding {
    func requestImage(for photo: LibraryPhoto, targetSize: CGSize, contentMode: PHImageContentMode,
                      completion: @escaping @MainActor (PhotoImageResult) -> Void) -> PHImageRequestID {
        Issue.record("Search unexpectedly requested an image")
        completion(.unavailable)
        return PHInvalidImageRequestID
    }
    func requestSource(for photo: LibraryPhoto,
                       completion: @escaping @MainActor (PhotoOCRSourceResult) -> Void) -> UUID {
        Issue.record("Search unexpectedly requested source bytes")
        completion(.unavailable)
        return UUID()
    }
    func checkAvailability(of photo: LibraryPhoto,
                           completion: @escaping @MainActor (PhotoAvailability) -> Void) -> UUID {
        Issue.record("Search unexpectedly checked source availability")
        completion(.unavailable)
        return UUID()
    }
    func cancel(_ requestID: UUID) { }
    func cancelRequest(_ requestID: PHImageRequestID) { }
    func cancelAll() { }
}
