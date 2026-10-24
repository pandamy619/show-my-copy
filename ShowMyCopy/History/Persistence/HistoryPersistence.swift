import Foundation

/// Why the history could not be saved or read. The cases carry no details: the underlying errors are logged
/// where they happen, without clipboard contents.
enum HistoryPersistenceError: Error, Equatable, Sendable {
    /// The store on disk could not be opened, so the history is kept in memory only until the app quits.
    case openFailed
    /// The store on disk could not be read and was moved aside; the history started empty.
    case storeReset
    /// The saved history could not be read.
    case loadFailed
    /// A change could not be written. The history in memory is still complete.
    case saveFailed
    /// A password could not be encrypted, so it is kept in memory only.
    case sealFailed

    /// A failure of one write, which the next successful write makes good. The others last for the session.
    var isWriteFailure: Bool {
        switch self {
        case .saveFailed, .sealFailed:
            true
        case .openFailed, .storeReset, .loadFailed:
            false
        }
    }
}

/// Where `PersistentHistoryStore` keeps the history between launches: plain records, no history rules.
///
/// Main-actor isolated and synchronous on purpose. The store writes each change right after making it, in order,
/// and learns at once whether it failed, so the history in memory and on disk cannot drift apart unnoticed. The
/// writes are small (one text entry per copy, a few at most per change) and the SwiftData context they go through
/// is itself bound to one actor; an actor here would add hops, ordering and `Sendable` snapshots for no gain.
/// Image data is written to a `BlobStore` off the main actor (`ImageIngestor`) before the entry is recorded, and
/// a record keeps only the blob IDs, in `payload` and in plain in `blobIDs`.
@MainActor
protocol HistoryPersistence: AnyObject {
    /// Every saved record, in any order.
    func loadAll() throws(HistoryPersistenceError) -> [StoredEntryRecord]

    /// Saves new records. A record whose ID is already saved replaces the saved one.
    func insert(_ records: [StoredEntryRecord]) throws(HistoryPersistenceError)

    /// Saves changed records in place of the saved ones with the same IDs. A record that is not saved yet is added.
    func update(_ records: [StoredEntryRecord]) throws(HistoryPersistenceError)

    /// Deletes the records with these IDs. IDs that are not saved are ignored.
    func delete(ids: [UUID]) throws(HistoryPersistenceError)

    /// Deletes every record, also those this app version could not load.
    func deleteAll() throws(HistoryPersistenceError)

    /// How many bytes the saved history takes on disk, or nil when it is not saved in files or their size is not
    /// known.
    func storedBytes() -> Int64?
}

extension HistoryPersistence {
    func storedBytes() -> Int64? {
        nil
    }
}

/// A history store that can say how much space the saved history takes on disk.
@MainActor
protocol ReportsDiskUsage: AnyObject {
    /// Bytes on disk, or nil when nothing is saved in files. Reads the file system, so call it only when the
    /// number is shown.
    func storedBytes() -> Int64?
}

/// Keeps records in memory only. Used when the store on disk cannot be opened: the app keeps working with the same
/// store type and can tell the user that nothing is saved.
@MainActor
final class InMemoryHistoryPersistence: HistoryPersistence {
    private var records: [UUID: StoredEntryRecord] = [:]

    init() {}

    func loadAll() -> [StoredEntryRecord] {
        Array(records.values)
    }

    func insert(_ records: [StoredEntryRecord]) {
        save(records)
    }

    func update(_ records: [StoredEntryRecord]) {
        save(records)
    }

    func delete(ids: [UUID]) {
        for id in ids {
            records[id] = nil
        }
    }

    func deleteAll() {
        records.removeAll()
    }

    private func save(_ newRecords: [StoredEntryRecord]) {
        for record in newRecords {
            records[record.id] = record
        }
    }
}
