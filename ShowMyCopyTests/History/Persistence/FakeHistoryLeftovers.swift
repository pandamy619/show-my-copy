import Foundation
import Synchronization

@testable import ShowMyCopy

/// Stands for the copy of a history that could not be opened, and the store itself while it cannot be opened. Its
/// size is read off the main actor, so the state is kept under a lock.
@MainActor
final class FakeHistoryLeftovers: HistoryLeftovers {
    private struct State {
        var hasDamagedCopy: Bool
        var hasUnopenedStore: Bool
        var damagedCopySize: Int64 = 3000
        var unopenedStoreSize: Int64 = 5000
    }

    private let state: Mutex<State>
    /// Deletes fail, like a file the system will not let go of.
    var deletesFail = false

    init(hasDamagedCopy: Bool = true, hasUnopenedStore: Bool = false) {
        state = Mutex(State(hasDamagedCopy: hasDamagedCopy, hasUnopenedStore: hasUnopenedStore))
    }

    var hasDamagedCopy: Bool {
        get { state.withLock { $0.hasDamagedCopy } }
        set { state.withLock { $0.hasDamagedCopy = newValue } }
    }

    var hasUnopenedStore: Bool {
        get { state.withLock { $0.hasUnopenedStore } }
        set { state.withLock { $0.hasUnopenedStore = newValue } }
    }

    var damagedCopySize: Int64 {
        get { state.withLock { $0.damagedCopySize } }
        set { state.withLock { $0.damagedCopySize = newValue } }
    }

    func hasFiles() -> Bool {
        hasDamagedCopy || hasUnopenedStore
    }

    func damagedCopyBytes() -> Int64? {
        hasDamagedCopy ? damagedCopySize : nil
    }

    nonisolated func totalBytes() -> Int64? {
        state.withLock { state in
            guard state.hasDamagedCopy || state.hasUnopenedStore else {
                return nil
            }
            return (state.hasDamagedCopy ? state.damagedCopySize : 0)
                + (state.hasUnopenedStore ? state.unopenedStoreSize : 0)
        }
    }

    func deleteDamagedCopy() -> Bool {
        if !deletesFail {
            hasDamagedCopy = false
        }
        return !hasDamagedCopy
    }

    func deleteAll() -> Bool {
        if !deletesFail {
            hasDamagedCopy = false
            hasUnopenedStore = false
        }
        return !hasFiles()
    }
}
