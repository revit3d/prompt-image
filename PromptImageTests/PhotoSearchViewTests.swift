import Foundation
import Photos
import SwiftUI
import Testing
import UIKit
@testable import PromptImage

/// Hosts the production screen and its real cover in the test app's window scene.
/// All photos, OCR, access checks, and image responses below are synthetic.
@Suite(.serialized)
@MainActor
struct PhotoSearchViewTests {
    @Test
    func closingTheRealViewerRestoresTheScrollPositionAndInvalidationDismissesIt() async throws {
        try await waitForSearchView("active test app scene") {
            UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene && $0.activationState == .foregroundActive }
        }
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let media = SearchViewMedia()
        let library = PhotoLibraryStore(access: PhotoLibraryAccess(provider: SearchViewAuthorization()),
            provider: SearchViewLibrary(), images: media,
            availability: PhotoAvailabilityScan(provider: media))
        let engine = SearchViewEngine()
        let summary = PhotoIndexSummary(totalCount: 50, completeCount: 30,
            embeddingCount: 40, ocrCount: 40, pendingCount: 20,
            downloadRequiredCount: 5, failedCount: 0)
        let store = PhotoSearchStore(engine: engine, indexState: {
            PhotoSearchIndexState(isReady: true, summary: summary, message: nil)
        })
        let host = UIHostingController(rootView: PhotoSearchView(library: library, store: store)
            .environment(\.scenePhase, .active))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .normal + 1
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            store.deactivate()
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        try await waitForSearchView("search screen appearance") {
            host.view.window != nil && host.view.bounds.height > 0
        }
        store.activate()
        store.text = "рецепт"
        store.search()
        await store.waitForIdle()
        try await waitForSearchView("scrollable results layout") {
            host.view.layoutIfNeeded()
            return resultsScrollView(in: host.view) != nil
        }
        let scroll = try #require(resultsScrollView(in: host.view))
        let destination = CGPoint(x: 0, y: 1_100)
        scroll.setContentOffset(destination, animated: false)
        try await waitForSearchView("scroll position observation") {
            abs(scroll.contentOffset.y - destination.y) < 2 && store.resultsScrollOffset > 1_000
        }
        let savedOffset = scroll.contentOffset.y
        let savedContext = store.resultContext
        let savedIDs = store.matches.map(\.photo.id)
        recordSearchViewImage(host.view, named: "Search-results-synthetic.png")

        store.select(engine.matches[10].photo)
        try await waitForSearchView("full-screen viewer presentation") {
            guard let viewer = searchPresentedController(in: host) else { return false }
            return viewer.view.window != nil && !viewer.isBeingPresented
                && searchDescendants(of: viewer.view).contains { $0 is PhotoZoomScrollView }
        }
        let viewer = try #require(searchPresentedController(in: host))
        recordSearchViewImage(viewer.view, named: "Search-viewer-synthetic.png")
        // Make restoration necessary even if UIKit happens to retain the hidden
        // scroll view unchanged during a normal full-screen presentation.
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        #expect(store.viewerReturnOffset != nil)
        store.dismissPhoto()
        try await waitForSearchView("viewer dismissal and scroll restoration") {
            searchPresentedController(in: host) == nil && store.viewerReturnOffset == nil
                && abs(scroll.contentOffset.y - savedOffset) < 2
        }

        #expect(store.text == "рецепт")
        #expect(store.resultContext == savedContext)
        #expect(store.matches.map(\.photo.id) == savedIDs)
        #expect(store.phase == .results)
        #expect(engine.searchCount == 1)

        store.select(engine.matches[10].photo)
        try await waitForSearchView("second viewer presentation") {
            guard let viewer = searchPresentedController(in: host) else { return false }
            return viewer.view.window != nil && !viewer.isBeingPresented
        }
        store.invalidateLibrary()
        #expect(store.selectedPhoto == nil)
        #expect(store.viewerReturnOffset == nil)
        #expect(store.resultContext == nil)
        #expect(store.snippets.isEmpty)
        #expect(store.matches.isEmpty)
        try await waitForSearchView("invalidated viewer dismissal") {
            searchPresentedController(in: host) == nil
        }
        #expect(store.resultsScrollOffset == 0)
        #expect(store.takeViewerReturnOffset() == nil)
        await store.waitForIdle()
    }
}

@MainActor
private func waitForSearchView(_ operation: String, condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(8))
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw SearchViewFailure.timedOut(operation)
}

@MainActor
private func searchDescendants(of view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { searchDescendants(of: $0) }
}

@MainActor
private func resultsScrollView(in view: UIView) -> UIScrollView? {
    searchDescendants(of: view).compactMap { $0 as? UIScrollView }
        .filter { !($0 is UITextView) && $0.bounds.height > 300
            && $0.contentSize.height > $0.bounds.height + 1_500 }
        .max { $0.contentSize.height < $1.contentSize.height }
}

@MainActor
private func searchPresentedController(in controller: UIViewController) -> UIViewController? {
    if let presented = controller.presentedViewController { return presented }
    return controller.children.lazy.compactMap { searchPresentedController(in: $0) }.first
}

@MainActor
private func recordSearchViewImage(_ view: UIView, named name: String) {
    guard view.bounds.width > 0, view.bounds.height > 0 else { return }
    let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
        view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    if let data = image.pngData() { Attachment.record(data, named: name) }
}

nonisolated private enum SearchViewFailure: Error { case timedOut(String) }

@MainActor
private final class SearchViewEngine: PhotoSearchServing {
    let matches: [PhotoSearchMatch] = (0..<40).map { index in
        PhotoSearchMatch(photo: LibraryPhoto(id: "synthetic-\(index)", creationDate: nil,
            modificationDate: nil, pixelWidth: 1_200, pixelHeight: 1_600),
            score: 1.0 / Double(index + 60), visualSimilarity: 0.4,
            recognizedText: "Рецепт яблочного пирога. Яблоки, мука, сахар и корица. Выпекать 40 минут.")
    }
    private(set) var searchCount = 0

    func search(_ text: String, language: QueryLanguageChoice, mode: PhotoSearchMode,
                limit: Int) async throws -> [PhotoSearchMatch] {
        searchCount += 1
        return Array(matches.prefix(limit))
    }
    func unload() async { }
}

@MainActor
private final class SearchViewAuthorization: PhotoLibraryAuthorizing {
    func authorizationStatus() -> PHAuthorizationStatus { .limited }
    func requestAuthorization() async -> PHAuthorizationStatus { .limited }
}

@MainActor
private final class SearchViewLibrary: PhotoLibraryProviding {
    func photos() async -> [LibraryPhoto] { [] }
    func startObserving(_ onChange: @escaping @MainActor @Sendable (PhotoLibraryChange) -> Void) { }
    func stopObserving() { }
}

@MainActor
private final class SearchViewMedia: PhotoImageProviding, PhotoAvailabilityProviding {
    private let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { context in
        UIColor.systemYellow.withAlphaComponent(0.25).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        ("Рецепт\nяблочного пирога\n\nЯблоки\nМука\nСахар\nКорица" as NSString).draw(
            in: CGRect(x: 24, y: 32, width: 252, height: 336),
            withAttributes: [.font: UIFont.systemFont(ofSize: 25), .foregroundColor: UIColor.black])
    }

    func requestImage(for photo: LibraryPhoto, targetSize: CGSize, contentMode: PHImageContentMode,
                      completion: @escaping @MainActor (PhotoImageResult) -> Void) -> PHImageRequestID {
        completion(.image(image))
        return PHInvalidImageRequestID
    }
    func cancelRequest(_ requestID: PHImageRequestID) { }
    func cancelAll() { }
    func checkAvailability(of photo: LibraryPhoto,
                           completion: @escaping @MainActor (PhotoAvailability) -> Void) -> UUID {
        Issue.record("The search screen must not scan source availability")
        completion(.unavailable)
        return UUID()
    }
    func cancel(_ requestID: UUID) { }
}
