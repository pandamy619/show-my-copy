import Foundation

@testable import ShowMyCopy

/// Storage of a history that is not saved anywhere: nothing goes wrong, nothing is on disk and no password waits.
/// Stands next to an `InMemoryHistoryStore` where a test needs an `AppHistory`.
@MainActor
final class UnsavedHistoryStorage: HistoryStorage {
    private(set) var damagedHistoryDeletions = 0
    private(set) var passwordKeyLoads = 0

    var storageError: HistoryPersistenceError? { nil }
    var damagedHistoryBytes: Int64? { nil }

    func deleteDamagedHistory() {
        damagedHistoryDeletions += 1
    }

    func storedBytes(recountingBlobs: Bool) async -> Int64? {
        nil
    }

    func loadPasswordKey() async {
        passwordKeyLoads += 1
    }
}

extension AppHistory {
    /// `store` kept in memory only, with storage that reports nothing.
    @MainActor
    static func unsaved(_ store: any HistoryStore = InMemoryHistoryStore()) -> AppHistory {
        AppHistory(store: store, storage: UnsavedHistoryStorage())
    }
}
