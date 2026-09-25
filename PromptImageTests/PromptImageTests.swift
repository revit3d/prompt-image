import Photos
import Testing
@testable import PromptImage

@MainActor
struct PhotoLibraryAccessTests {
    @Test(arguments: [
        PHAuthorizationStatus.notDetermined,
        .authorized,
        .limited,
        .denied,
        .restricted,
    ])
    func initializationReadsPermissionWithoutRequestingIt(status: PHAuthorizationStatus) {
        let provider = AuthorizationStub(status: status)

        let access = PhotoLibraryAccess(provider: provider)

        #expect(access.status == status)
        #expect(!access.isRequesting)
        #expect(provider.requestCount == 0)
    }

    @Test
    func refreshReflectsRevocationAndRestorationWithoutPrompting() {
        let provider = AuthorizationStub(status: .authorized)
        let access = PhotoLibraryAccess(provider: provider)

        for status in [PHAuthorizationStatus.denied, .limited, .authorized, .restricted] {
            provider.currentStatus = status
            access.refresh()

            #expect(access.status == status)
            #expect(!access.isRequesting)
            #expect(provider.requestCount == 0)
        }
    }

    @Test
    func refreshingUndeterminedPermissionDoesNotPrompt() {
        let provider = AuthorizationStub(status: .notDetermined)
        let access = PhotoLibraryAccess(provider: provider)

        access.refresh()
        access.refresh()

        #expect(access.status == .notDetermined)
        #expect(provider.requestCount == 0)
    }

    @Test(arguments: [
        PHAuthorizationStatus.authorized,
        .limited,
        .denied,
        .restricted,
    ])
    func userRequestUsesThePermissionResult(result: PHAuthorizationStatus) async {
        let provider = AuthorizationStub(status: .notDetermined, result: result)
        let access = PhotoLibraryAccess(provider: provider)

        await access.requestAccess()

        #expect(access.status == result)
        #expect(!access.isRequesting)
        #expect(provider.requestCount == 1)
    }

    @Test(arguments: [
        PHAuthorizationStatus.authorized,
        .limited,
        .denied,
        .restricted,
    ])
    func determinedPermissionIsNotRequestedAgain(status: PHAuthorizationStatus) async {
        let provider = AuthorizationStub(status: status)
        let access = PhotoLibraryAccess(provider: provider)

        await access.requestAccess()
        await access.requestAccess()

        #expect(access.status == status)
        #expect(!access.isRequesting)
        #expect(provider.requestCount == 0)
    }

    @Test
    func requestChecksForPermissionChangesBeforePrompting() async {
        let provider = AuthorizationStub(status: .notDetermined)
        let access = PhotoLibraryAccess(provider: provider)
        provider.currentStatus = .limited

        await access.requestAccess()

        #expect(access.status == .limited)
        #expect(provider.requestCount == 0)
    }

    @Test
    func requestRecognizesPermissionResetSinceTheLastRefresh() async {
        let provider = AuthorizationStub(status: .denied, result: .authorized)
        let access = PhotoLibraryAccess(provider: provider)
        provider.currentStatus = .notDetermined

        await access.requestAccess()

        #expect(access.status == .authorized)
        #expect(!access.isRequesting)
        #expect(provider.requestCount == 1)
    }

    @Test
    func repeatedTapWhileRequestIsPendingDoesNotStartAnotherRequest() async {
        let provider = AuthorizationStub(status: .notDetermined, suspendsRequest: true)
        let access = PhotoLibraryAccess(provider: provider)
        let firstRequest = Task { await access.requestAccess() }
        await provider.waitUntilRequestBegins()

        #expect(access.isRequesting)
        await access.requestAccess()
        #expect(provider.requestCount == 1)

        provider.completeRequest(with: .limited)
        await firstRequest.value

        #expect(access.status == .limited)
        #expect(!access.isRequesting)
        await access.requestAccess()
        #expect(provider.requestCount == 1)
    }
}

@MainActor
private final class AuthorizationStub: PhotoLibraryAuthorizing {
    var currentStatus: PHAuthorizationStatus
    private(set) var requestCount = 0
    private let result: PHAuthorizationStatus
    private let suspendsRequest: Bool
    private var pendingResponse: CheckedContinuation<PHAuthorizationStatus, Never>?
    private var requestBegan: CheckedContinuation<Void, Never>?

    init(
        status: PHAuthorizationStatus,
        result: PHAuthorizationStatus = .authorized,
        suspendsRequest: Bool = false
    ) {
        currentStatus = status
        self.result = result
        self.suspendsRequest = suspendsRequest
    }

    func authorizationStatus() -> PHAuthorizationStatus {
        currentStatus
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        requestCount += 1
        let response: PHAuthorizationStatus
        if suspendsRequest && requestCount == 1 {
            response = await withCheckedContinuation { continuation in
                pendingResponse = continuation
                requestBegan?.resume()
                requestBegan = nil
            }
        } else {
            response = result
        }
        currentStatus = response
        return response
    }

    func waitUntilRequestBegins() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { continuation in
            requestBegan = continuation
        }
    }

    func completeRequest(with status: PHAuthorizationStatus) {
        let response = pendingResponse
        pendingResponse = nil
        response?.resume(returning: status)
    }
}
