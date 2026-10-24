import Foundation
import Synchronization

@testable import ShowMyCopy

/// Keeps records in a dictionary, like a store on disk that outlives the history store, and can be told to fail.
/// Each `apply` is all or nothing, like a transaction.
@MainActor
final class FakeHistoryPersistence: HistoryPersistence {
    enum Operation: Hashable {
        case loadAll, apply
    }

    var records: [UUID: StoredEntryRecord] = [:]
    /// Operations that throw instead of changing anything.
    var failing: Set<Operation> = []
    /// Calls that throw instead of changing anything, by their number in `calls` counting from 1, also the calls
    /// before `resetCalls()`: the n-th operation fails.
    var failingCalls: Set<Int> = []
    /// Every call, in order, also the failed ones.
    private(set) var calls: [Operation] = []
    /// Every change passed to `apply`, also the failed ones.
    private(set) var changes: [StoredChange] = []
    /// What `storedBytes()` returns, like the size of the files on disk, how often it was called, and how many of
    /// those calls ran on the main thread. Read off the main actor, so kept under a lock.
    private let measured = Mutex((bytes: Int64?.none, reads: 0, readsOnMainThread: 0))

    var bytesOnDisk: Int64? {
        get { measured.withLock { $0.bytes } }
        set { measured.withLock { $0.bytes = newValue } }
    }

    var storedBytesReadCount: Int {
        measured.withLock { $0.reads }
    }

    var storedBytesReadsOnMainThread: Int {
        measured.withLock { $0.readsOnMainThread }
    }
    private var callCount = 0

    /// The number the next call gets, for `failingCalls`.
    var nextCall: Int {
        callCount + 1
    }

    func record(_ id: UUID) -> StoredEntryRecord? {
        records[id]
    }

    func loadAll() throws(HistoryPersistenceError) -> [StoredEntryRecord] {
        try perform(.loadAll, error: .loadFailed)
        // Any order, as the protocol allows; sorted the other way round to catch callers that rely on it.
        return records.values.sorted { $0.date < $1.date }
    }

    func apply(_ change: StoredChange) throws(HistoryPersistenceError) {
        changes.append(change)
        try perform(.apply)
        if change.deletesAll {
            records.removeAll()
        }
        for id in change.deleted {
            records[id] = nil
        }
        for record in change.saved {
            records[record.id] = record
        }
    }

    nonisolated func storedBytes() -> Int64? {
        let isMainThread = Thread.isMainThread
        return measured.withLock { measured in
            measured.reads += 1
            measured.readsOnMainThread += isMainThread ? 1 : 0
            return measured.bytes
        }
    }

    func resetCalls() {
        calls.removeAll()
        changes.removeAll()
    }

    private func perform(
        _ operation: Operation,
        error: HistoryPersistenceError = .saveFailed
    ) throws(HistoryPersistenceError) {
        calls.append(operation)
        callCount += 1
        if failing.contains(operation) || failingCalls.contains(callCount) {
            throw error
        }
    }
}

extension FakeHistoryPersistence {
    /// A store on this persistence. Making another one stands for quitting and starting the app.
    func makeStore(
        sealer: (any SecretSealing)? = FakeSecretSealer(),
        savesPasswords: Bool = true,
        retention: RetentionPolicy = .default,
        now: Date,
        openError: HistoryPersistenceError? = nil,
        blobs: (any BlobStore)? = nil,
        leftovers: (any HistoryLeftovers)? = nil
    ) -> PersistentHistoryStore {
        PersistentHistoryStore.loadedNow(
            persistence: self, sealer: sealer, savesPasswords: savesPasswords, retention: retention, now: now,
            openError: openError, blobs: blobs, leftovers: leftovers)
    }

    /// The texts of the saved records that `sealer` can read.
    func savedTexts(sealer: FakeSecretSealer = FakeSecretSealer()) -> Set<String> {
        let coder = StoredEntryCoder(sealer: sealer, hasher: SHA256ContentHasher())
        return Set(
            records.values.compactMap { record in
                guard case .entry(let entry) = coder.decode(record) else {
                    return nil
                }
                return entry.text
            })
    }
}

/// The single-purpose writes the tests use to set up a saved history, as changes of one kind each.
extension HistoryPersistence {
    func insert(_ records: [StoredEntryRecord]) throws(HistoryPersistenceError) {
        try apply(StoredChange(saved: records))
    }

    func update(_ records: [StoredEntryRecord]) throws(HistoryPersistenceError) {
        try apply(StoredChange(saved: records))
    }

    func delete(ids: [UUID]) throws(HistoryPersistenceError) {
        try apply(StoredChange(deleted: ids))
    }

    func deleteAll() throws(HistoryPersistenceError) {
        try apply(StoredChange(deletesAll: true))
    }
}
