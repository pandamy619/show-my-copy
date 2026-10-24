import Foundation

@testable import ShowMyCopy

/// Stands for the copy of a history that could not be opened, and the store itself while it cannot be opened.
@MainActor
final class FakeHistoryLeftovers: HistoryLeftovers {
    var hasDamagedCopy: Bool
    var hasUnopenedStore: Bool

    init(hasDamagedCopy: Bool = true, hasUnopenedStore: Bool = false) {
        self.hasDamagedCopy = hasDamagedCopy
        self.hasUnopenedStore = hasUnopenedStore
    }

    func hasFiles() -> Bool {
        hasDamagedCopy || hasUnopenedStore
    }
}
