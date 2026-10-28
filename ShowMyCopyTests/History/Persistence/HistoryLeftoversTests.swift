import Foundation
import Testing

@testable import ShowMyCopy

/// Copies of a history that could not be opened go with Clear History, with saved passwords, and after a week.
@MainActor
struct HistoryLeftoversTests {
    private let disk = FakeHistoryPersistence()
    private let blobs = InMemoryBlobStore()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeStore(
        leftovers: FakeHistoryLeftovers,
        openError: HistoryPersistenceError? = nil,
        persistence: (any HistoryPersistence)? = nil
    ) -> PersistentHistoryStore {
        PersistentHistoryStore.loadedNow(
            persistence: persistence ?? disk, sealer: FakeSecretSealer(), savesPasswords: true, now: start,
            openError: openError, blobs: blobs, leftovers: leftovers)
    }

    // MARK: - Clear History

    @Test func clearDeletesTheDamagedCopyAndThenEveryImage() throws {
        let leftovers = FakeHistoryLeftovers()
        let image = try ContentFixtures.storedImage(in: blobs)
        let store = makeStore(leftovers: leftovers, openError: .storeReset)
        store.record(text: "a", sourceApp: nil, at: start)

        store.clear()
        #expect(!leftovers.hasFiles())
        #expect(store.damagedHistoryBytes == nil)
        // No copy of a history is left, so no image is used any more.
        #expect(!blobs.contains(image.blobID))
    }

    /// The store that could not be opened is the saved history: Clear History deletes it too.
    @Test func clearDeletesTheStoreThatCouldNotBeOpened() async throws {
        let leftovers = FakeHistoryLeftovers(hasDamagedCopy: false, hasUnopenedStore: true)
        _ = try ContentFixtures.storedImage(in: blobs)
        let store = makeStore(leftovers: leftovers, openError: .openFailed, persistence: InMemoryHistoryPersistence())
        store.record(text: "a", sourceApp: nil, at: start)

        store.clear()
        #expect(!leftovers.hasFiles())
        #expect(blobs.allIDs().isEmpty)
        #expect(await store.storedBytes(recountingBlobs: false) == nil)
    }

    @Test func imagesAreKeptWhenTheCopyCannotBeDeleted() throws {
        let leftovers = FakeHistoryLeftovers()
        leftovers.deletesFail = true
        let image = try ContentFixtures.storedImage(in: blobs)
        let store = makeStore(leftovers: leftovers)

        store.clear()
        #expect(leftovers.hasDamagedCopy)
        #expect(store.damagedHistoryBytes == 3000)
        #expect(blobs.allIDs() == Set(image.blobIDs))
    }

    @Test func imagesAreKeptWhenTheRecordsCannotBeDeleted() throws {
        let leftovers = FakeHistoryLeftovers()
        let image = try ContentFixtures.storedImage(in: blobs)
        let store = makeStore(leftovers: leftovers)
        disk.failing = [.apply]

        store.clear()
        #expect(!leftovers.hasFiles())
        #expect(blobs.allIDs() == Set(image.blobIDs))
    }

    // MARK: - Saved passwords

    @Test func deletingTheDamagedCopyKeepsTheStoreThatCouldNotBeOpened() {
        let leftovers = FakeHistoryLeftovers(hasDamagedCopy: true, hasUnopenedStore: true)
        let store = makeStore(leftovers: leftovers, openError: .openFailed, persistence: InMemoryHistoryPersistence())
        #expect(store.damagedHistoryBytes == 3000)

        store.deleteDamagedHistory()
        #expect(!leftovers.hasDamagedCopy)
        // Loading it at a later launch deletes its passwords when saving them is off.
        #expect(leftovers.hasUnopenedStore)
        #expect(store.damagedHistoryBytes == nil)
    }

    @Test func turningOffSavePasswordsDeletesTheDamagedCopy() throws {
        try TestDefaults.with { defaults in
            let leftovers = FakeHistoryLeftovers()
            let store = makeStore(leftovers: leftovers)
            let settings = PasswordSettings(history: AppHistory(store), defaults: defaults, now: { Date() })
            settings.savesPasswords = true
            #expect(leftovers.hasDamagedCopy)

            settings.savesPasswords = false
            #expect(!leftovers.hasDamagedCopy)
        }
    }

    /// With saving off from the start, the copy was made from a store whose passwords were already deleted.
    @Test func startingWithSavePasswordsOffKeepsTheDamagedCopy() throws {
        try TestDefaults.with { defaults in
            let leftovers = FakeHistoryLeftovers()
            let store = makeStore(leftovers: leftovers)
            _ = PasswordSettings(history: AppHistory(store), defaults: defaults, now: { Date() })
            store.removeConcealed()
            #expect(leftovers.hasDamagedCopy)
        }
    }

    // MARK: - Size

    @Test func sizeOnDiskIncludesTheLeftovers() async throws {
        disk.bytesOnDisk = 4096
        let leftovers = FakeHistoryLeftovers()
        let store = makeStore(leftovers: leftovers)
        #expect(await store.storedBytes(recountingBlobs: false) == Int64(4096 + 3000))

        let notOpened = FakeHistoryLeftovers(hasDamagedCopy: false, hasUnopenedStore: true)
        let inMemory = makeStore(
            leftovers: notOpened, openError: .openFailed, persistence: InMemoryHistoryPersistence())
        #expect(await inMemory.storedBytes(recountingBlobs: false) == 5000)
    }

    @Test func storageSettingsShowTheDamagedCopy() {
        let leftovers = FakeHistoryLeftovers()
        let store = makeStore(leftovers: leftovers)
        let usage = StorageUsage(history: AppHistory(store), memoryReader: NoMemoryUsage())
        #expect(usage.damagedHistoryBytes == 3000)
        #expect(usage.hasSomethingToClear)

        store.deleteDamagedHistory()
        #expect(usage.damagedHistoryBytes == nil)
        #expect(!usage.hasSomethingToClear)
        #expect(StorageUsage(history: .unsaved(), memoryReader: NoMemoryUsage()).damagedHistoryBytes == nil)
    }
}

/// The files on disk.
@MainActor
struct LeftoverStoreFilesTests {
    private func files(in folder: URL, unopened: Bool = false) -> LeftoverStoreFiles {
        LeftoverStoreFiles(
            damagedStore: folder.appending(path: "History.store.damaged"),
            unopenedStore: unopened ? folder.appending(path: "History.store") : nil)
    }

    @Test func sizesAndDeletesTheDamagedCopyWithItsSideFiles() throws {
        try TemporaryFolder.with { folder in
            try TemporaryFolder.write(Data(count: 100), to: "History.store.damaged", in: folder)
            try TemporaryFolder.write(Data(count: 20), to: "History.store.damaged-wal", in: folder)
            try TemporaryFolder.write(Data(count: 7), to: "History.store", in: folder)
            let leftovers = files(in: folder)
            #expect(leftovers.damagedCopyBytes() == 120)
            #expect(leftovers.totalBytes() == 120)

            #expect(leftovers.deleteDamagedCopy())
            #expect(!TemporaryFolder.exists("History.store.damaged", in: folder))
            #expect(!TemporaryFolder.exists("History.store.damaged-wal", in: folder))
            #expect(TemporaryFolder.exists("History.store", in: folder))
            #expect(leftovers.damagedCopyBytes() == nil)
            #expect(!leftovers.hasFiles())
        }
    }

    @Test func theStoreThatCouldNotBeOpenedIsALeftoverToo() throws {
        try TemporaryFolder.with { folder in
            try TemporaryFolder.write(Data(count: 7), to: "History.store", in: folder)
            try TemporaryFolder.write(Data(count: 3), to: "History.store-shm", in: folder)
            let leftovers = files(in: folder, unopened: true)
            #expect(leftovers.hasFiles())
            #expect(leftovers.damagedCopyBytes() == nil)
            #expect(leftovers.totalBytes() == 10)

            #expect(leftovers.deleteAll())
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).isEmpty)
            #expect(leftovers.totalBytes() == nil)
        }
    }

    @Test func nothingToDeleteIsFine() throws {
        try TemporaryFolder.with { folder in
            #expect(files(in: folder, unopened: true).deleteAll())
            #expect(files(in: folder).deleteDamagedCopy())
        }
    }
}
