@testable import ShowMyCopy

/// Records what the history window and the entry copier ask of the clipboard monitor, in order.
@MainActor
final class ChangeTrackerSpy: PasteboardChangeTracking {
    enum Call: Equatable {
        case poll
        case acknowledge(changeCount: Int)
        case userIsActive
        case historyWindowOpened(Bool)
    }

    private(set) var calls: [Call] = []
    /// What the monitor says it saw last; an acknowledged change sets it, as in the monitor.
    var handledChangeCount: Int?

    func poll() {
        calls.append(.poll)
    }

    func acknowledge(changeCount: Int) {
        calls.append(.acknowledge(changeCount: changeCount))
        handledChangeCount = changeCount
    }

    func userIsActive() {
        calls.append(.userIsActive)
    }

    func historyWindowOpened(_ isOpen: Bool) {
        calls.append(.historyWindowOpened(isOpen))
    }
}
