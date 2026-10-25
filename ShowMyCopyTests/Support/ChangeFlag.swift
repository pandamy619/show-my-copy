import Synchronization

/// Set from an observation callback, which may run on any thread.
final class ChangeFlag: Sendable {
    private let isSet = Mutex(false)

    var value: Bool {
        isSet.withLock { $0 }
    }

    func set() {
        isSet.withLock { $0 = true }
    }
}
