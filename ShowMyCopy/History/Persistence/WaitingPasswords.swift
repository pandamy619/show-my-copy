import Foundation

/// Saved passwords that wait on disk, unopened, until the key can be used: it is not loaded yet, the Mac is locked
/// or access was denied. Each record says in plain when it expires, so they expire and are deleted without the key.
struct WaitingPasswords: Sendable {
    private(set) var records: [StoredEntryRecord]

    init(_ records: [StoredEntryRecord] = []) {
        self.records = records
    }

    var isEmpty: Bool {
        records.isEmpty
    }

    /// Stops waiting for the records `shouldRemove` picks and returns their IDs.
    mutating func remove(where shouldRemove: (StoredEntryRecord) -> Bool) -> [UUID] {
        let removed = records.filter(shouldRemove).map(\.id)
        records.removeAll(where: shouldRemove)
        return removed
    }

    /// Moves every expiry to `date` at the latest, like `HistoryStore.limitExpiry(to:)`, and returns the records it
    /// changed, to be written.
    mutating func limitExpiry(to date: Date) -> [StoredEntryRecord] {
        var changed: [StoredEntryRecord] = []
        for index in records.indices where records[index].expiresAt.map({ $0 > date }) != false {
            records[index].expiresAt = date
            changed.append(records[index])
        }
        return changed
    }

    /// Opens the records with `coder`. Returns the entries it opened and the IDs of those it cannot open, which are
    /// of no use any more; those whose key still cannot be used go on waiting.
    mutating func open(with coder: StoredEntryCoder) -> (entries: [ClipboardEntry], unreadable: [UUID]) {
        var entries: [ClipboardEntry] = []
        var unreadable: [UUID] = []
        var waiting: [StoredEntryRecord] = []
        for record in records {
            switch coder.decode(record) {
            case .entry(let entry):
                entries.append(entry)
            case .unreadable:
                unreadable.append(record.id)
            case .waitsForKey:
                waiting.append(record)
            }
        }
        records = waiting
        return (entries, unreadable)
    }
}
