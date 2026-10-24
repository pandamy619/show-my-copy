import Foundation
import SwiftData
import os

/// Saves history records with SwiftData. Only create, read, update and delete: the history rules live in
/// `PersistentHistoryStore` and the mapping (with sealing) in `StoredEntryCoder`.
///
/// Every change is saved at once in one transaction and rolled back on failure, so the store learns about a failed
/// write right away, the disk keeps what it had, and the next write does not carry a half-applied one.
@MainActor
final class SwiftDataHistoryPersistence: HistoryPersistence {
    static let schema = Schema([StoredEntry.self])

    private let container: ModelContainer
    private let context: ModelContext
    /// The SQLite file, or nil for a store in memory.
    private let storeURL: URL?

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
        storeURL = configuration.isStoredInMemoryOnly ? nil : configuration.url
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

    /// Deletes and saves in one `save()`, so one SQLite transaction: a failure rolls all of it back.
    func apply(_ change: StoredChange) throws(HistoryPersistenceError) {
        guard !change.isEmpty else {
            return
        }
        let savedIDs = Set(change.saved.map(\.id))
        let deletedIDs = change.deleted.filter { !savedIDs.contains($0) }
        try save { context in
            if change.deletesAll {
                try deleteModels(in: context, keeping: savedIDs)
            } else if !deletedIDs.isEmpty {
                try deleteModels(in: context, with: deletedIDs)
            }
            try upsert(change.saved, in: context)
        }
    }

    /// The size of `History.store` and its SQLite side files. It need not drop right after entries are deleted:
    /// SQLite may keep the free space for new ones.
    func storedBytes() -> Int64? {
        storeURL.flatMap(StoreFiles.totalBytes(ofStoreAt:))
    }

    /// Marks every saved model except those with `kept` IDs as deleted. Fetched with their IDs only, so the
    /// payloads are not read; deleted through the context, so the deletion is part of the same save.
    private func deleteModels(in context: ModelContext, keeping kept: Set<UUID>) throws {
        var descriptor = FetchDescriptor<StoredEntry>()
        descriptor.propertiesToFetch = [\.id]
        for model in try context.fetch(descriptor) where !kept.contains(model.id) {
            context.delete(model)
        }
    }

    private func deleteModels(in context: ModelContext, with ids: [UUID]) throws {
        var descriptor = FetchDescriptor<StoredEntry>(predicate: #Predicate<StoredEntry> { ids.contains($0.id) })
        descriptor.propertiesToFetch = [\.id]
        for model in try context.fetch(descriptor) {
            context.delete(model)
        }
    }

    /// Changes the saved models with the records' IDs and adds the others. Done by hand rather than left to the
    /// unique constraint, so a new and a changed record behave the same whatever SwiftData does on a conflict.
    private func upsert(_ records: [StoredEntryRecord], in context: ModelContext) throws {
        guard !records.isEmpty else {
            return
        }
        let ids = records.map(\.id)
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
        for suffix in StoreFiles.suffixes {
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
