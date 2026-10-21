@testable import ShowMyCopy

/// Records what the history window and the entry copier ask of the clipboard monitor, in order.
@MainActor
final class ChangeTrackerSpy: PasteboardChangeTracking {
    enum Call: Equatable {
        case poll
        case acknowledge(changeCount: Int)
        case userIsActive
    }

    private(set) var calls: [Call] = []

    func poll() {
        calls.append(.poll)
    }

    func acknowledge(changeCount: Int) {
        calls.append(.acknowledge(changeCount: changeCount))
    }

    func userIsActive() {
        calls.append(.userIsActive)
    }
}
