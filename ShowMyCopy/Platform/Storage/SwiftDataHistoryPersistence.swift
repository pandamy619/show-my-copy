import Foundation
import SwiftData
import os

/// Saves history records with SwiftData. Only create, read, update and delete: the history rules live in
/// `PersistentHistoryStore` and the mapping (with sealing) in `StoredEntryCoder`.
///
/// Every call saves at once and rolls back on failure, so the store learns about a failed write right away and the
/// next write does not carry a half-applied one.
@MainActor
final class SwiftDataHistoryPersistence: HistoryPersistence {
    static let schema = Schema([StoredEntry.self])

    private let container: ModelContainer
    private let context: ModelContext

    /// Opens the store described by `configuration`. Use `open(in:)` for the app's store and `inMemory()` in
    /// tests.
    init(configuration: ModelConfiguration) throws(HistoryPersistenceError) {
        do {
            container = try ModelContainer(for: Self.schema, configurations: [configuration])
        } catch {
            AppLogger.history.error(
                "Could not open the history store: \(String(describing: error), privacy: .private)")
            throw .openFailed
        }
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    /// A store that lives in memory only, for tests.
    static func inMemory() throws(HistoryPersistenceError) -> SwiftDataHistoryPersistence {
        // A unique name, so two stores in one process never share their contents.
        try SwiftDataHistoryPersistence(
            configuration: ModelConfiguration(
                UUID().uuidString, schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    func loadAll() throws(HistoryPersistenceError) -> [StoredEntryRecord] {
        do {
            return try context.fetch(FetchDescriptor<StoredEntry>()).map(\.record)
        } catch {
            AppLogger.history.error("Could not read the history: \(String(describing: error), privacy: .private)")
            throw .loadFailed
        }
    }

    func insert(_ records: [StoredEntryRecord]) throws(HistoryPersistenceError) {
        try upsert(records)
    }

    func update(_ records: [StoredEntryRecord]) throws(HistoryPersistenceError) {
        try upsert(records)
    }

    func delete(ids: [UUID]) throws(HistoryPersistenceError) {
        guard !ids.isEmpty else {
            return
        }
        try save { context in
            try context.delete(model: StoredEntry.self, where: #Predicate<StoredEntry> { ids.contains($0.id) })
        }
    }

    func deleteAll() throws(HistoryPersistenceError) {
        try save { context in
            try context.delete(model: StoredEntry.self)
        }
    }

    /// Changes the saved models with the records' IDs and adds the others. Done by hand rather than left to the
    /// unique constraint, so inserting and updating behave the same whatever SwiftData does on a conflict.
    private func upsert(_ records: [StoredEntryRecord]) throws(HistoryPersistenceError) {
        guard !records.isEmpty else {
            return
        }
        let ids = records.map(\.id)
        try save { context in
            let saved = FetchDescriptor<StoredEntry>(predicate: #Predicate<StoredEntry> { ids.contains($0.id) })
            let existing = try context.fetch(saved)
            var models = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for record in records {
                if let model = models[record.id] {
                    model.update(from: record)
                } else {
                    let model = StoredEntry(record: record)
                    context.insert(model)
                    models[record.id] = model
                }
            }
        }
    }

    private func save(_ changes: (ModelContext) throws -> Void) throws(HistoryPersistenceError) {
        do {
            try changes(context)
            try context.save()
        } catch {
            context.rollback()
            AppLogger.history.error("Could not save the history: \(String(describing: error), privacy: .private)")
            throw .saveFailed
        }
    }
}

// MARK: - Opening the app's store

extension SwiftDataHistoryPersistence {
    /// A persistence to use, and what went wrong opening the store on disk, if anything.
    struct Opened {
        let persistence: any HistoryPersistence
        let error: HistoryPersistenceError?
    }

    static let storeFileName = "History.store"
    /// Where a store that could not be opened is moved. Only the latest one is kept.
    static let damagedStoreFileName = "History.store.damaged"
    /// SQLite keeps recent changes in these files next to the store until it checkpoints them.
    private static let storeFileSuffixes = ["", "-wal", "-shm"]

    /// Opens the history in Application Support/ShowMyCopy, inside the app's sandbox container.
    static func openDefault() -> Opened {
        let directory: URL
        do {
            directory = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "ShowMyCopy", directoryHint: .isDirectory)
        } catch {
            AppLogger.history.error(
                "Could not find Application Support: \(String(describing: error), privacy: .private)")
            return Opened(persistence: InMemoryHistoryPersistence(), error: .openFailed)
        }
        return open(in: directory)
    }

    /// Opens or creates `History.store` in `directory`. A store that cannot be opened (damaged, or from a format
    /// this version cannot migrate) is moved aside and a new, empty one is started (`storeReset`). When even that
    /// fails, the history is kept in memory only (`openFailed`): the app still works, it just forgets on quit.
    static func open(in directory: URL) -> Opened {
        do {
            try prepare(directory)
        } catch {
            AppLogger.history.error(
                "Could not create the history folder: \(String(describing: error), privacy: .private)")
            return Opened(persistence: InMemoryHistoryPersistence(), error: .openFailed)
        }
        let storeURL = directory.appending(path: storeFileName, directoryHint: .notDirectory)
        do {
            return Opened(persistence: try openStore(at: storeURL), error: nil)
        } catch {
            // What failed is logged by `init(configuration:)`.
            AppLogger.history.error("Moving the history store aside and starting a new one")
        }
        do {
            try moveAside(in: directory)
            return Opened(persistence: try openStore(at: storeURL), error: .storeReset)
        } catch {
            AppLogger.history.error("Could not start a new history store; keeping the history in memory only")
            return Opened(persistence: InMemoryHistoryPersistence(), error: .openFailed)
        }
    }

    private static func openStore(at url: URL) throws(HistoryPersistenceError) -> SwiftDataHistoryPersistence {
        // No sync: the clipboard history never leaves this Mac. The app has no CloudKit entitlement either, but
        // `.automatic` would start syncing as soon as one was added.
        try SwiftDataHistoryPersistence(
            configuration: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
    }

    /// Creates the folder and excludes it from backups. The history can hold anything that was copied, so it
    /// should not end up in Time Machine or other backups, where deleting an entry no longer removes it.
    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = directory
        do {
            try directory.setResourceValues(values)
        } catch {
            // Not a reason to stop saving: the history is still in the sandbox container.
            AppLogger.history.error(
                "Could not exclude the history from backups: \(String(describing: error), privacy: .private)")
        }
    }

    /// Moves the store and its SQLite side files to `damagedStoreFileName`, replacing an older damaged copy. Kept,
    /// not deleted, so the history can still be recovered by hand; it stays in the folder excluded from backups.
    private static func moveAside(in directory: URL) throws {
        let fileManager = FileManager.default
        for suffix in storeFileSuffixes {
            let source = directory.appending(path: storeFileName + suffix, directoryHint: .notDirectory)
            let destination = directory.appending(path: damagedStoreFileName + suffix, directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try fileManager.removeItem(at: destination)
            }
            if fileManager.fileExists(atPath: source.path(percentEncoded: false)) {
                try fileManager.moveItem(at: source, to: destination)
            }
        }
    }
}
