import Foundation

@testable import ShowMyCopy

/// Keeps records in a dictionary, like a store on disk that outlives the history store, and can be told to fail.
@MainActor
final class FakeHistoryPersistence: HistoryPersistence {
    enum Operation: Hashable {
        case loadAll, insert, update, delete, deleteAll
    }

    var records: [UUID: StoredEntryRecord] = [:]
    /// Operations that throw instead of changing anything.
    var failing: Set<Operation> = []
    /// Every call, in order, also the failed ones.
    private(set) var calls: [Operation] = []

    func record(_ id: UUID) -> StoredEntryRecord? {
        records[id]
    }

    func loadAll() throws(HistoryPersistenceError) -> [StoredEntryRecord] {
        try perform(.loadAll, error: .loadFailed)
        // Any order, as the protocol allows; sorted the other way round to catch callers that rely on it.
        return records.values.sorted { $0.date < $1.date }
    }

    func insert(_ records: [StoredEntryRecord]) throws(HistoryPersistenceError) {
        try perform(.insert)
        save(records)
    }

    func update(_ records: [StoredEntryRecord]) throws(HistoryPersistenceError) {
        try perform(.update)
        save(records)
    }

    func delete(ids: [UUID]) throws(HistoryPersistenceError) {
        try perform(.delete)
        for id in ids {
            records[id] = nil
        }
    }

    func deleteAll() throws(HistoryPersistenceError) {
        try perform(.deleteAll)
        records.removeAll()
    }

    func resetCalls() {
        calls.removeAll()
    }

    private func perform(
        _ operation: Operation,
        error: HistoryPersistenceError = .saveFailed
    ) throws(HistoryPersistenceError) {
        calls.append(operation)
        if failing.contains(operation) {
            throw error
        }
    }

    private func save(_ newRecords: [StoredEntryRecord]) {
        for record in newRecords {
            records[record.id] = record
        }
    }
}
