import Foundation
import SwiftData
import Testing

@testable import ShowMyCopy

@MainActor
struct SwiftDataHistoryPersistenceTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let defaultsSuite = "ShowMyCopyTests.\(UUID().uuidString)"
    private var defaults: UserDefaults {
        UserDefaults(suiteName: defaultsSuite) ?? .standard
    }

    private func makeRecord(
        id: UUID = UUID(),
        text: String = "hello",
        date: Date? = nil,
        isConcealed: Bool = false
    ) -> StoredEntryRecord {
        StoredEntryRecord(
            id: id,
            kind: "text",
            payload: Data(text.utf8),
            contentHash: isConcealed ? nil : "00ff",
            byteSize: isConcealed ? 0 : text.utf8.count,
            previewText: isConcealed ? nil : text,
            date: date ?? self.date,
            sourceAppBundleIdentifier: "com.apple.Notes",
            sourceAppName: "Notes",
            isConcealed: isConcealed,
            expiresAt: isConcealed ? self.date + 600 : nil,
            isPinned: false
        )
    }

    private func sorted(_ records: [StoredEntryRecord]) -> [StoredEntryRecord] {
        records.sorted { $0.date > $1.date }
    }

    /// Opens the store in `directory` with its own count of failed launches, not the app's.
    private func open(in directory: URL) -> SwiftDataHistoryPersistence.Opened {
        SwiftDataHistoryPersistence.open(in: directory, defaults: defaults)
    }

    /// A new folder in the temporary directory, removed after `body`.
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ShowMyCopyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Could not remove the temporary directory: \(error)")
            }
        }
        try body(directory)
    }

    @Test func recordsRoundTripWithEveryField() throws {
        let persistence = try SwiftDataHistoryPersistence.inMemory()
        let plain = makeRecord(text: "plain", date: date + 1)
        let concealed = makeRecord(text: "sealed bytes", isConcealed: true)
        let noApp = StoredEntryRecord(
            id: UUID(), kind: "text", payload: Data(), contentHash: "ab", byteSize: 0, previewText: "",
            date: date - 1, sourceAppBundleIdentifier: nil, sourceAppName: nil, isConcealed: false,
            expiresAt: nil, isPinned: true)

        try persistence.insert([plain, concealed, noApp])
        #expect(sorted(try persistence.loadAll()) == [plain, concealed, noApp])
    }

    @Test func updateReplacesSavedRecordsAndAddsMissingOnes() throws {
        let persistence = try SwiftDataHistoryPersistence.inMemory()
        let original = makeRecord(text: "hello")
        try persistence.insert([original])

        var moved = original
        moved.date = date + 10
        moved.sourceAppName = "Safari"
        let added = makeRecord(text: "new", date: date + 5)
        try persistence.update([moved, added])

        #expect(sorted(try persistence.loadAll()) == [moved, added])
    }

    @Test func idsAreUnique() throws {
        let persistence = try SwiftDataHistoryPersistence.inMemory()
        let id = UUID()
        try persistence.insert([makeRecord(id: id, text: "first")])
        try persistence.insert([makeRecord(id: id, text: "second", date: date + 1)])

        let records = try persistence.loadAll()
        #expect(records.count == 1)
        #expect(records.first?.payload == Data("second".utf8))
    }

    @Test func deleteRemovesOnlyTheGivenIDs() throws {
        let persistence = try SwiftDataHistoryPersistence.inMemory()
        let kept = makeRecord(text: "kept", date: date + 1)
        let removed = makeRecord(text: "removed")
        try persistence.insert([kept, removed])

        try persistence.delete(ids: [removed.id, UUID()])
        #expect(try persistence.loadAll() == [kept])
    }

    @Test func deleteAllRemovesEverything() throws {
        let persistence = try SwiftDataHistoryPersistence.inMemory()
        try persistence.insert([makeRecord(text: "a"), makeRecord(text: "b", date: date + 1)])

        try persistence.deleteAll()
        #expect(try persistence.loadAll().isEmpty)
    }

    @Test func oneChangeDeletesAndSaves() throws {
        let persistence = try SwiftDataHistoryPersistence.inMemory()
        let kept = makeRecord(text: "kept", date: date + 2)
        let removed = makeRecord(text: "removed", date: date + 1)
        var changed = makeRecord(text: "old")
        try persistence.insert([kept, removed, changed])

        changed.date = date + 3
        let added = makeRecord(text: "added", date: date + 4)
        try persistence.apply(StoredChange(deleted: [removed.id], saved: [changed, added]))
        #expect(sorted(try persistence.loadAll()) == [added, changed, kept])
    }

    @Test func aRecordBothDeletedAndSavedIsSaved() throws {
        let persistence = try SwiftDataHistoryPersistence.inMemory()
        var record = makeRecord()
        try persistence.insert([record])

        record.date = date + 1
        try persistence.apply(StoredChange(deleted: [record.id], saved: [record]))
        #expect(try persistence.loadAll() == [record])
    }

    @Test func deletingAllKeepsOnlyTheSavedRecords() throws {
        let persistence = try SwiftDataHistoryPersistence.inMemory()
        var changed = makeRecord(text: "changed")
        try persistence.insert([changed, makeRecord(text: "gone", date: date + 1)])

        changed.date = date + 5
        let added = makeRecord(text: "added", date: date + 2)
        try persistence.apply(StoredChange(deletesAll: true, saved: [changed, added]))
        #expect(sorted(try persistence.loadAll()) == [changed, added])
    }

    @Test func emptyChangesDoNothing() throws {
        let persistence = try SwiftDataHistoryPersistence.inMemory()
        let record = makeRecord()
        try persistence.insert([record])

        try persistence.insert([])
        try persistence.update([])
        try persistence.delete(ids: [])
        try persistence.apply(StoredChange())
        #expect(try persistence.loadAll() == [record])
    }

    @Test func storesInMemoryAreSeparate() throws {
        let first = try SwiftDataHistoryPersistence.inMemory()
        let second = try SwiftDataHistoryPersistence.inMemory()
        try first.insert([makeRecord()])
        #expect(try second.loadAll().isEmpty)
    }

    @Test func historySurvivesReopeningTheStoreOnDisk() throws {
        try withTemporaryDirectory { directory in
            let record = makeRecord()
            let first = open(in: directory)
            #expect(first.error == nil)
            #expect(first.persistence is SwiftDataHistoryPersistence)
            try first.persistence.insert([record])

            let second = open(in: directory)
            #expect(second.error == nil)
            #expect(try second.persistence.loadAll() == [record])
        }
    }

    @Test func storeFolderIsExcludedFromBackups() throws {
        try withTemporaryDirectory { directory in
            _ = open(in: directory)
            let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true)
        }
    }

    @Test func damagedStoreIsMovedAsideAndANewOneStarts() throws {
        try withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let storeURL = directory.appending(path: HistoryStoreOpener.storeFileName)
            try Data(repeating: 0x42, count: 4096).write(to: storeURL)

            let opened = open(in: directory)
            #expect(opened.error == .storeReset)
            #expect(opened.persistence is SwiftDataHistoryPersistence)
            #expect(try opened.persistence.loadAll().isEmpty)
            let damaged = directory.appending(path: HistoryStoreOpener.damagedStoreFileName)
            #expect(FileManager.default.fileExists(atPath: damaged.path(percentEncoded: false)))

            try opened.persistence.insert([makeRecord()])
            #expect(try open(in: directory).persistence.loadAll().count == 1)
        }
    }

    /// A database that is damaged inside still starts with the SQLite header: it may be another build's, so it is
    /// left where it is until it has failed on several launches in a row.
    @Test func aDamagedDatabaseIsKeptUntilItFailsOnSeveralLaunches() throws {
        try withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let storeURL = directory.appending(path: HistoryStoreOpener.storeFileName)
            let damagedDatabase = StoreFileCheck.sqliteHeader + Data(repeating: 0x42, count: 4080)
            try damagedDatabase.write(to: storeURL)
            defer { defaults.removePersistentDomain(forName: defaultsSuite) }

            for _ in 1..<HistoryStoreOpener.failedLaunchesBeforeReset {
                let opened = open(in: directory)
                #expect(opened.error == .openFailed)
                #expect(opened.persistence is InMemoryHistoryPersistence)
                #expect(FileManager.default.contents(atPath: storeURL.path(percentEncoded: false)) == damagedDatabase)
            }
            let opened = open(in: directory)
            #expect(opened.error == .storeReset)
            #expect(opened.persistence is SwiftDataHistoryPersistence)
            let damaged = directory.appending(path: HistoryStoreOpener.damagedStoreFileName)
            #expect(FileManager.default.contents(atPath: damaged.path(percentEncoded: false)) == damagedDatabase)
        }
    }

    @Test func storeInMemoryHasNoSizeOnDisk() throws {
        let persistence = try SwiftDataHistoryPersistence.inMemory()
        try persistence.insert([makeRecord()])
        #expect(persistence.storedBytes() == nil)
    }

    @Test func sizeOnDiskIsTheSizeOfTheStoreFiles() throws {
        try withTemporaryDirectory { directory in
            let opened = open(in: directory)
            try opened.persistence.insert([makeRecord(text: String(repeating: "a", count: 10_000))])

            let storeURL = directory.appending(path: HistoryStoreOpener.storeFileName)
            let bytes = try #require(opened.persistence.storedBytes())
            #expect(bytes > 10_000)
            #expect(bytes == StoreFiles.totalBytes(ofStoreAt: storeURL))
        }
    }

    @Test func persistentStoreRoundTripsThroughSwiftData() throws {
        let persistence = try SwiftDataHistoryPersistence.inMemory()
        let first = PersistentHistoryStore.loadedNow(
            persistence: persistence, sealer: FakeSecretSealer(), savesPasswords: true, now: date)
        first.record(text: "plain", sourceApp: nil, at: date)
        first.record(text: "hunter2", sourceApp: nil, at: date + 1, concealed: true, expiresAt: date + 600)

        let second = PersistentHistoryStore.loadedNow(
            persistence: persistence, sealer: FakeSecretSealer(), savesPasswords: true, now: date + 2)
        #expect(second.entries == first.entries)
        #expect(second.storageError == nil)
        let saved = try persistence.loadAll()
        #expect(!saved.contains { $0.payload.range(of: Data("hunter2".utf8)) != nil })
    }
}
