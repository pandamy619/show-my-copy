import Foundation

@testable import ShowMyCopy

/// Stands for the copy of a history that could not be opened, and the store itself while it cannot be opened.
@MainActor
final class FakeHistoryLeftovers: HistoryLeftovers {
    var hasDamagedCopy: Bool
    var hasUnopenedStore: Bool
    var damagedCopySize: Int64 = 3000
    var unopenedStoreSize: Int64 = 5000
    /// Deletes fail, like a file the system will not let go of.
    var deletesFail = false

    init(hasDamagedCopy: Bool = true, hasUnopenedStore: Bool = false) {
        self.hasDamagedCopy = hasDamagedCopy
        self.hasUnopenedStore = hasUnopenedStore
    }

    func hasFiles() -> Bool {
        hasDamagedCopy || hasUnopenedStore
    }

    func damagedCopyBytes() -> Int64? {
        hasDamagedCopy ? damagedCopySize : nil
    }

    func totalBytes() -> Int64? {
        hasFiles() ? (damagedCopyBytes() ?? 0) + (hasUnopenedStore ? unopenedStoreSize : 0) : nil
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
