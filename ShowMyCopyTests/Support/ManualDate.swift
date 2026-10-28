import Foundation

/// A wall clock that moves only when a test moves it, for code that takes a `now` closure returning a `Date`.
@MainActor
final class ManualDate {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }

    /// Pass this where the code takes a `now` closure.
    var read: @MainActor () -> Date {
        { [unowned self] in self.now }
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
    }
}
