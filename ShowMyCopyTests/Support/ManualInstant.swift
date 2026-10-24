import Foundation

/// A clock that moves only when a test moves it, for code that compares instants of `ContinuousClock`.
@MainActor
final class ManualInstant {
    private(set) var now = ContinuousClock.now

    /// Pass this where the code takes a `now` closure.
    var read: @MainActor () -> ContinuousClock.Instant {
        { [unowned self] in self.now }
    }

    func advance(by duration: Duration) {
        now += duration
    }
}
