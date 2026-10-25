import Foundation

@testable import ShowMyCopy

extension PersistentHistoryStore {
    /// Loads the saved history in the steps `load` takes at launch, without leaving the main actor, so a test reads
    /// the store right after making it. The store's clock stands still at `now` unless a test gives it `clock`.
    static func loadedNow(
        persistence: any HistoryPersistence,
        sealer: (any SecretSealing)?,
        savesPasswords: Bool,
        retention: RetentionPolicy = .default,
        hasher: any ContentHasher = SHA256ContentHasher(),
        now: Date = Date(),
        clock: (@MainActor () -> Date)? = nil,
        openError: HistoryPersistenceError? = nil,
        blobs: (any BlobStore)? = nil,
        leftovers: (any HistoryLeftovers)? = nil
    ) -> PersistentHistoryStore {
        let read = LoadedHistory.read(from: persistence, openError: openError, leftovers: leftovers)
        let loaded = LoadedHistory.sorted(
            read, coder: StoredEntryCoder(sealer: sealer, hasher: hasher), savesPasswords: savesPasswords, at: now,
            blobs: blobs)
        return PersistentHistoryStore(
            persistence: persistence, loaded: loaded, sealer: sealer, retention: retention, hasher: hasher,
            now: clock ?? { now }, openError: openError, blobs: blobs, leftovers: leftovers)
    }
}
