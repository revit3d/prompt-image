import Testing
@testable import PromptImage

struct PhotoLibraryFetchBaselineTests {
    @Test
    func firstCompletedFetchEstablishesBaseline() {
        var baseline = PhotoLibraryFetchBaseline<String>()
        let generation = baseline.beginFetch()
        baseline.adoptFetch("initial", generation: generation)
        #expect(baseline.value == "initial")
    }

    @Test
    func lateFetchCannotReplaceAdvancedObserverBaseline() {
        var baseline = PhotoLibraryFetchBaseline<String>()
        let first = baseline.beginFetch()
        baseline.adoptFetch("initial", generation: first)
        let slow = baseline.beginFetch()
        baseline.recordChange("edited")
        baseline.adoptFetch("stale", generation: slow)
        #expect(baseline.value == "edited")

        let refreshed = baseline.beginFetch()
        baseline.adoptFetch("current", generation: refreshed)
        #expect(baseline.value == "edited")
    }

    @Test
    func notificationWithoutDetailsAlsoInvalidatesOutstandingFetch() {
        var baseline = PhotoLibraryFetchBaseline<String>()
        let generation = baseline.beginFetch()
        baseline.recordChange()
        baseline.adoptFetch("superseded", generation: generation)
        #expect(baseline.value == nil)
    }

    @Test
    func permissionResetRejectsPreviousFetchEvenAfterNewBaselineExists() {
        var baseline = PhotoLibraryFetchBaseline<String>()
        let old = baseline.beginFetch()
        baseline.reset()
        let current = baseline.beginFetch()
        baseline.adoptFetch("permitted", generation: current)
        baseline.adoptFetch("previous-access", generation: old)
        #expect(baseline.value == "permitted")
    }

    @Test
    func newerFetchWinsEvenWhenOlderFetchReturnsLast() {
        var baseline = PhotoLibraryFetchBaseline<String>()
        let old = baseline.beginFetch()
        let current = baseline.beginFetch()
        baseline.adoptFetch("newer", generation: current)
        baseline.adoptFetch("older", generation: old)
        #expect(baseline.value == "newer")
    }

    @Test
    func refreshCannotSkipAnEditWhoseObserverNotificationIsStillPending() {
        var baseline = PhotoLibraryFetchBaseline<String>()
        let first = baseline.beginFetch()
        baseline.adoptFetch("before-edit", generation: first)

        let refresh = baseline.beginFetch()
        baseline.adoptFetch("already-edited", generation: refresh)
        #expect(baseline.value == "before-edit")

        baseline.recordChange("after-observed-edit")
        #expect(baseline.value == "after-observed-edit")
    }
}
