import Foundation

/// A single callback request bridged to structured cancellation. Provider.cancel
/// deliberately has no completion, so this bridge must settle its own continuation.
@MainActor
final class PhotoIndexSourceRequest {
    private let provider: any PhotoOCRSourceProviding
    private var continuation: CheckedContinuation<PhotoOCRSourceResult, Error>?
    private var requestID: UUID?

    init(provider: any PhotoOCRSourceProviding) { self.provider = provider }

    func source(for photo: LibraryPhoto) async throws -> PhotoOCRSourceResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let id = provider.requestSource(for: photo) { [weak self] result in
                    guard let self, let pending = self.continuation else { return }
                    self.continuation = nil
                    self.requestID = nil
                    pending.resume(returning: result)
                }
                if self.continuation != nil { requestID = id }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func cancel() {
        let pending = continuation
        continuation = nil
        let id = requestID
        requestID = nil
        if let id { provider.cancel(id) }
        pending?.resume(throwing: CancellationError())
    }
}
