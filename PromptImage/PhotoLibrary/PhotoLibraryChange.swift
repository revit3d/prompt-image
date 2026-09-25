import Foundation

/// Content invalidation is separate from metadata refresh: PhotoKit can report
/// changed image bytes without changing the dates or dimensions we store.
nonisolated struct PhotoLibraryChange: Sendable, Equatable {
    var contentChangedIDs: Set<String> = []
    var requiresFullReindex = false
}

/// A detached fetch must never replace a baseline already advanced by an
/// observer notification, a newer fetch, or a permission reset.
nonisolated struct PhotoLibraryFetchBaseline<Snapshot> {
    private(set) var value: Snapshot?
    private var generation = 0

    mutating func beginFetch() -> Int {
        generation += 1
        return generation
    }

    mutating func adoptFetch(_ snapshot: Snapshot, generation: Int) {
        guard generation == self.generation, value == nil else { return }
        // A fetch may already contain an edit whose notification has not been
        // delivered yet. Only PHChange may advance an established baseline.
        value = snapshot
    }

    mutating func recordChange(_ snapshot: Snapshot? = nil) {
        generation += 1
        if let snapshot { value = snapshot }
    }

    mutating func reset() {
        generation += 1
        value = nil
    }
}
