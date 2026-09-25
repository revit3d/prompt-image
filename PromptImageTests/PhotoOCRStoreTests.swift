import Foundation
import ImageIO
import Testing
@testable import PromptImage

@MainActor
struct PhotoOCRStoreTests {
    @Test
    func openingDoesNotStartRecognitionAndSynchronousSourceFinishesCleanly() async {
        let provider = OCRSourceStub(synchronousResult: .source(source("Рецепт pancakes")))
        let engine = OCRRecognizerStub()
        let store = PhotoOCRStore(provider: provider, engine: engine)
        let photo = photo("selected")

        store.activate(for: photo)
        #expect(provider.requests.isEmpty)
        #expect(await engine.callCount == 0)
        store.start()
        await store.waitForIdle()

        #expect(provider.requests.first?.photo == photo)
        #expect(store.result?.text == "Рецепт pancakes")
        #expect(store.result?.revision == 3)
        #expect(!store.isWorking)
        store.cancel()
        #expect(store.result == nil)
        #expect(provider.cancelled.isEmpty)
    }

    @Test(arguments: [true, false])
    func sourceFailureIsRetryableAndNeverStartsRecognition(cloud: Bool) async {
        let provider = OCRSourceStub()
        let engine = OCRRecognizerStub()
        let store = PhotoOCRStore(provider: provider, engine: engine)
        store.activate(for: photo("selected"))
        store.start()
        #expect(store.operation == .loading)
        provider.complete(0, with: cloud ? .requiresDownload : .unavailable)

        #expect(store.sourceFailure == (cloud ? .requiresDownload : .unavailable))
        #expect(!store.isWorking)
        #expect(await engine.callCount == 0)
        store.start()
        #expect(store.sourceFailure == nil)
        provider.complete(1, with: .source(source("retry")))
        await store.waitForIdle()
        #expect(store.result?.text == "retry")
        #expect(provider.cancelled.isEmpty)
    }

    @Test
    func cancelPendingSourceRejectsLateAndDuplicateCallbacks() async {
        let provider = OCRSourceStub()
        let engine = OCRRecognizerStub()
        let store = PhotoOCRStore(provider: provider, engine: engine)
        store.activate(for: photo("selected"))
        store.start()
        store.cancel()
        store.cancel()
        #expect(provider.cancelled == [provider.requests[0].id])
        #expect(!store.isWorking)

        store.start()
        provider.complete(0, with: .source(source("stale")))
        #expect(store.operation == .loading)
        provider.complete(1, with: .source(source("current")))
        provider.complete(1, with: .requiresDownload)
        await store.waitForIdle()
        provider.complete(0, with: .unavailable)

        #expect(store.result?.text == "current")
        #expect(store.sourceFailure == nil)
        #expect(await engine.callCount == 1)
    }

    @Test(arguments: [true, false])
    func cancellationWaitsForRecognitionAndRejectsItsLateResultOrError(failure: Bool) async {
        let provider = OCRSourceStub(synchronousResult: .source(source("old")))
        let engine = OCRRecognizerStub()
        await engine.setDeferred(true)
        let store = PhotoOCRStore(provider: provider, engine: engine)
        store.activate(for: photo("selected"))
        store.start()
        await engine.waitForCalls(1)
        store.cancel()
        store.start()

        #expect(store.isWorking)
        #expect(store.isCancelling)
        #expect(provider.requests.count == 1)
        #expect(await engine.callCount == 1)
        await engine.setFailure(failure)
        await engine.finish()
        await store.waitForIdle()

        #expect(!store.isWorking)
        #expect(!store.isCancelling)
        #expect(store.result == nil)
        #expect(store.message == nil)
        #expect(provider.cancelled.isEmpty)

        await engine.setDeferred(false)
        await engine.setFailure(false)
        store.start()
        await store.waitForIdle()
        #expect(store.result?.text == "old")
        #expect(await engine.callCount == 2)
    }

    @Test
    func reopeningDuringCancelledRecognitionCannotOverlapWorkOrPublishOldText() async {
        let provider = OCRSourceStub(synchronousResult: .source(source("private text")))
        let engine = OCRRecognizerStub()
        await engine.setDeferred(true)
        let store = PhotoOCRStore(provider: provider, engine: engine)
        let photo = photo("selected")
        store.activate(for: photo)
        store.start()
        await engine.waitForCalls(1)
        store.deactivate()
        store.start()
        store.activate(for: photo)
        store.start()
        #expect(provider.requests.count == 1)

        await engine.finish()
        await store.waitForIdle()
        #expect(store.result == nil)
        #expect(!store.isWorking)
        #expect(await engine.callCount == 1)
    }

    @Test
    func deactivationClearsCompletedTextAndRequiresExplicitStartAfterActivation() async {
        let provider = OCRSourceStub(synchronousResult: .source(source("private text")))
        let engine = OCRRecognizerStub()
        let store = PhotoOCRStore(provider: provider, engine: engine)
        let photo = photo("selected")
        store.activate(for: photo)
        store.start()
        await store.waitForIdle()
        #expect(store.result != nil)

        store.deactivate()
        store.start()
        #expect(store.result == nil)
        #expect(provider.requests.count == 1)
        store.activate(for: photo)
        #expect(store.result == nil)
        #expect(provider.requests.count == 1)
    }

    @Test
    func modifiedPhotoCancelsSourceAndRejectsOldVersion() async {
        let provider = OCRSourceStub()
        let engine = OCRRecognizerStub()
        let store = PhotoOCRStore(provider: provider, engine: engine)
        store.activate(for: photo("same", modified: 1))
        store.start()
        let changed = photo("same", modified: 2)
        store.activate(for: changed)
        #expect(provider.cancelled == [provider.requests[0].id])
        store.start()
        provider.complete(0, with: .source(source("old version")))
        #expect(store.operation == .loading)
        provider.complete(1, with: .source(source("new version")))
        await store.waitForIdle()

        #expect(provider.requests.last?.photo == changed)
        #expect(store.result?.text == "new version")
        #expect(await engine.callCount == 1)
    }

    @Test
    func changedPhotoRejectsInFlightRecognitionBeforeAllowingNewWork() async {
        let provider = OCRSourceStub()
        let engine = OCRRecognizerStub()
        await engine.setDeferred(true)
        let store = PhotoOCRStore(provider: provider, engine: engine)
        store.activate(for: photo("old"))
        store.start()
        provider.complete(0, with: .source(source("old text")))
        await engine.waitForCalls(1)

        store.activate(for: photo("new"))
        store.start()
        #expect(store.isCancelling)
        #expect(provider.requests.count == 1)
        await engine.finish()
        await store.waitForIdle()
        #expect(store.result == nil)

        await engine.setDeferred(false)
        store.start()
        provider.complete(1, with: .source(source("new text")))
        await store.waitForIdle()
        #expect(provider.requests.last?.photo.id == "new")
        #expect(store.result?.text == "new text")
    }

    @Test
    func emptyRecognitionIsAResultAndErrorsDoNotExposePrivateDetails() async {
        let provider = OCRSourceStub(synchronousResult: .source(source("")))
        let engine = OCRRecognizerStub()
        let store = PhotoOCRStore(provider: provider, engine: engine)
        store.activate(for: photo("selected"))
        store.start()
        await store.waitForIdle()
        #expect(store.result?.lines.isEmpty == true)
        #expect(store.message == nil)

        await engine.setFailure(true)
        store.start()
        await store.waitForIdle()
        #expect(store.result == nil)
        #expect(store.message == "Не удалось распознать текст. Попробуйте снова.")
        await engine.setFailure(false)
        store.start()
        await store.waitForIdle()
        #expect(store.result != nil)
        #expect(store.message == nil)
    }

    private func source(_ text: String) -> PhotoOCRSource {
        PhotoOCRSource(data: Data(text.utf8), orientation: .up)
    }

    private func photo(_ id: String, modified: TimeInterval = 1) -> LibraryPhoto {
        LibraryPhoto(id: id, creationDate: nil,
                     modificationDate: Date(timeIntervalSince1970: modified),
                     pixelWidth: 1_000, pixelHeight: 2_000)
    }
}

@MainActor
private final class OCRSourceStub: PhotoOCRSourceProviding {
    struct Request {
        let id: UUID
        let photo: LibraryPhoto
        let completion: @MainActor (PhotoOCRSourceResult) -> Void
    }

    private(set) var requests: [Request] = []
    private(set) var cancelled: [UUID] = []
    private let synchronousResult: PhotoOCRSourceResult?

    init(synchronousResult: PhotoOCRSourceResult? = nil) {
        self.synchronousResult = synchronousResult
    }

    func requestSource(for photo: LibraryPhoto,
                       completion: @escaping @MainActor (PhotoOCRSourceResult) -> Void) -> UUID {
        let id = UUID()
        requests.append(Request(id: id, photo: photo, completion: completion))
        if let synchronousResult { completion(synchronousResult) }
        return id
    }

    func cancel(_ id: UUID) { cancelled.append(id) }

    func complete(_ index: Int, with result: PhotoOCRSourceResult) {
        // Keep callbacks available to reproduce delivery after cancellation.
        requests[index].completion(result)
    }
}

private actor OCRRecognizerStub: PhotoTextRecognizing {
    private(set) var callCount = 0
    private var deferred = false
    private var fails = false
    private var pending: CheckedContinuation<Void, Never>?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func setDeferred(_ deferred: Bool) { self.deferred = deferred }
    func setFailure(_ fails: Bool) { self.fails = fails }

    func recognize(_ source: PhotoOCRSource) async throws -> PhotoOCRResult {
        callCount += 1
        if deferred {
            // A synchronous Vision call may finish despite task cancellation.
            await withCheckedContinuation {
                pending = $0
                releaseWaiters()
            }
        } else {
            releaseWaiters()
        }
        if fails { throw OCRStubError.privateDetails }
        let text = String(decoding: source.data, as: UTF8.self)
        let lines = text.isEmpty ? [] : [PhotoOCRLine(
            text: text, confidence: 0.9, boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1)
        )]
        return PhotoOCRResult(lines: lines, revision: 3, languages: ["ru-RU", "en-US"])
    }

    func waitForCalls(_ count: Int) async {
        if callCount >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func finish() {
        let continuation = pending
        pending = nil
        continuation?.resume()
    }

    private func releaseWaiters() {
        let ready = waiters.filter { callCount >= $0.0 }
        waiters.removeAll { callCount >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
    }
}

private enum OCRStubError: LocalizedError {
    case privateDetails
    var errorDescription: String? { "private source text must not be shown in an error" }
}
