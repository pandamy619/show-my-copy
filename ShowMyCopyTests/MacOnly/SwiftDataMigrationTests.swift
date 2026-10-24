import Foundation
import SwiftData
import Testing

@testable import ShowMyCopy

/// The SwiftData model as version 1 of the app saved it (schema version 1, before `blobIDs`). Kept here only to
/// make a store in the old format; the entity name is the class name, as for the app's model.
private enum HistoryStoreV1 {
    @Model
    final class StoredEntry {
        #Unique<StoredEntry>([\.id])
        #Index<StoredEntry>([\.date])

        var id: UUID
        var kind: String
        var payload: Data
        var contentHash: String?
        var byteSize: Int
        var previewText: String?
        var date: Date
        var sourceAppBundleIdentifier: String?
        var sourceAppName: String?
        var isConcealed: Bool
        var expiresAt: Date?
        var isPinned: Bool
        var schemaVersion: Int

        init(id: UUID, text: String, date: Date) {
            self.id = id
            kind = "text"
            payload = Data(text.utf8)
            contentHash = "00ff"
            byteSize = text.utf8.count
            previewText = text
            self.date = date
            sourceAppBundleIdentifier = "com.apple.Notes"
            sourceAppName = "Notes"
            isConcealed = false
            expiresAt = nil
            isPinned = false
            schemaVersion = 1
        }
    }
}

@MainActor
struct SwiftDataMigrationTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    /// A new folder in the temporary directory, removed after `body`.
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ShowMyCopyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Could not remove the temporary directory: \(error)")
            }
        }
        try body(directory)
    }

    private func imageRecord() -> StoredEntryRecord {
        StoredEntryRecord(
            id: UUID(), kind: "image", payload: Data([1, 2, 3]), contentHash: "ab", byteSize: 1100,
            previewText: "PNG 640 × 480", date: date + 1, sourceAppBundleIdentifier: nil, sourceAppName: nil,
            isConcealed: false, expiresAt: nil, isPinned: false, schemaVersion: 2, blobIDs: [UUID(), UUID()])
    }

    @Test func blobIDsRoundTrip() throws {
        let persistence = try SwiftDataHistoryPersistence.inMemory()
        let image = imageRecord()
        var withoutBlobs = imageRecord()
        withoutBlobs.blobIDs = []
        try persistence.insert([image, withoutBlobs])
        let loaded = try persistence.loadAll()
        #expect(Set(loaded.map(\.id)) == [image.id, withoutBlobs.id])
        #expect(loaded.first { $0.id == image.id } == image)
        #expect(loaded.first { $0.id == withoutBlobs.id } == withoutBlobs)

        var changed = image
        changed.blobIDs = [UUID()]
        try persistence.update([changed])
        #expect(try persistence.loadAll().first { $0.id == image.id }?.blobIDs == changed.blobIDs)
    }

    /// Version 2 only adds an optional attribute, so SwiftData migrates a version 1 store on its own (a
    /// lightweight migration) instead of failing to open it, which would move the history aside.
    @Test func storeSavedByVersionOneOpensWithItsEntries() throws {
        try withTemporaryDirectory { directory in
            let storeURL = directory.appending(path: SwiftDataHistoryPersistence.storeFileName)
            let id = UUID()
            try autoreleasepool {
                let oldSchema = Schema([HistoryStoreV1.StoredEntry.self])
                let container = try ModelContainer(
                    for: oldSchema,
                    configurations: [ModelConfiguration(schema: oldSchema, url: storeURL, cloudKitDatabase: .none)])
                let context = ModelContext(container)
                context.insert(HistoryStoreV1.StoredEntry(id: id, text: "from version 1", date: date))
                try context.save()
            }

            let opened = SwiftDataHistoryPersistence.open(in: directory)
            #expect(opened.error == nil)
            let records = try opened.persistence.loadAll()
            #expect(records.map(\.id) == [id])
            let record = try #require(records.first)
            #expect(record.payload == Data("from version 1".utf8))
            #expect(record.schemaVersion == 1)
            #expect(record.blobIDs.isEmpty)

            // The migrated store keeps the new attribute.
            let image = imageRecord()
            try opened.persistence.insert([image])
            #expect(try opened.persistence.loadAll().first { $0.id == image.id } == image)
            let damaged = directory.appending(path: SwiftDataHistoryPersistence.damagedStoreFileName)
            #expect(!FileManager.default.fileExists(atPath: damaged.path(percentEncoded: false)))
        }
    }
}
