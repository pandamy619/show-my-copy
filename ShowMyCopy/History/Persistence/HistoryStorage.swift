import Foundation

/// Where the history is saved, as Settings and the app see it: whether saving works, how much space it takes on
/// disk, a damaged copy of a history and the key of saved passwords.
///
/// The composition root hands it out next to the store (`AppHistory`), so nothing has to ask a `HistoryStore` at
/// run time what else it can do. `PersistentHistoryStore` is the one implementation.
@MainActor
protocol HistoryStorage: AnyObject, Sendable {
    /// Why the history is not, or not fully, saved; nil while saving works. Views that read it are updated when it
    /// changes.
    var storageError: HistoryPersistenceError? { get }

    /// The size of a copy of a history that could not be opened (see `HistoryLeftovers`), or nil when there is
    /// none. Views that read it are updated when it changes.
    var damagedHistoryBytes: Int64? { get }

    /// Deletes the copy of a history that could not be opened.
    func deleteDamagedHistory()

    /// Bytes on disk, or nil when nothing is saved in files, measured off the main actor. Saved images are counted
    /// from a running total; `recountingBlobs` counts them again from the disk. Call it only when the number is shown.
    func storedBytes(recountingBlobs: Bool) async -> Int64?

    /// Loads the key off the main actor when a saved password waits for it, then opens the saved passwords and saves
    /// those copied meanwhile. Does nothing, and never asks the Keychain, when no password waits.
    func loadPasswordKey() async
}

/// The history the app runs on: the store every part of the app reads and changes, and where it is saved. Both are
/// the same `PersistentHistoryStore` in the app.
struct AppHistory: Sendable {
    let store: any HistoryStore
    let storage: any HistoryStorage

    init(store: any HistoryStore, storage: any HistoryStorage) {
        self.store = store
        self.storage = storage
    }

    init(_ store: PersistentHistoryStore) {
        self.init(store: store, storage: store)
    }
}
