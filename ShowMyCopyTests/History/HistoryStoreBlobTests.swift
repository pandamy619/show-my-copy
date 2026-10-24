import Foundation
import Testing

@testable import ShowMyCopy

/// A blob store whose deletes fail, like a file the system will not let go of.
private final class UndeletableBlobStore: BlobStore {
    let inner = InMemoryBlobStore()

    func write(_ data: Data) -> BlobID { inner.write(data) }
    func read(_ id: BlobID) throws(BlobStoreError) -> Data { try inner.read(id) }
    func delete(_ ids: [BlobID]) throws(BlobStoreError) { throw .deleteFailed }
    func size(of id: BlobID) -> Int? { inner.size(of: id) }
    func totalBytes() -> Int64 { inner.totalBytes() }
    func allIDs() -> Set<BlobID> { inner.allIDs() }
}

@MainActor
struct InMemoryHistoryStoreBlobTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let blobs = InMemoryBlobStore()

    private func makeStore(retention: RetentionPolicy = .default) -> InMemoryHistoryStore {
        InMemoryHistoryStore(retention: retention, blobs: blobs)
    }

    private func storedImage(_ byte: UInt8 = 7, size: Int = 1000) throws -> ImageReference {
        try ContentFixtures.storedImage(in: blobs, bytes: Data(repeating: byte, count: size))
    }

    @Test func removingAnImageDeletesItsBlobs() throws {
        let store = makeStore()
        let image = try storedImage()
        let id = store.record(.image(image), sourceApp: nil, at: start)
        store.record(text: "text", sourceApp: nil, at: start + 1)
        #expect(blobs.allIDs().count == 2)

        store.remove(id: id)
        #expect(blobs.allIDs().isEmpty)
        #expect(store.entries.map(\.text) == ["text"])
    }

    @Test func imagesPushedOutByTheEntryLimitLoseTheirBlobs() throws {
        let store = makeStore(retention: RetentionPolicy(entryLimit: 10))
        let first = try storedImage(1)
        store.record(.image(first), sourceApp: nil, at: start)
        for index in 1...10 {
            store.record(text: "text \(index)", sourceApp: nil, at: start + Double(index))
        }
        #expect(store.entries.count == 10)
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func byteLimitCountsTheImageDataAndThumbnail() throws {
        let store = makeStore(retention: RetentionPolicy(byteLimit: 2000))
        store.record(.image(try storedImage(1, size: 1000)), sourceApp: nil, at: start)
        #expect(store.stats() == HistoryStats(count: 1, totalBytes: 1100))

        // 1100 + 1100 is over the limit: the older image goes, with its blobs.
        let newer = try storedImage(2, size: 1000)
        store.record(.image(newer), sourceApp: nil, at: start + 1)
        #expect(store.entries.map(\.content) == [.image(newer)])
        #expect(blobs.allIDs() == Set(newer.blobIDs))
    }

    @Test func imageLargerThanTheByteLimitIsNotKept() throws {
        let store = makeStore(retention: RetentionPolicy(byteLimit: 500))
        store.record(.image(try storedImage()), sourceApp: nil, at: start)
        #expect(store.entries.isEmpty)
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func clearDeletesEveryBlobAndCountsTheirBytes() throws {
        let store = makeStore()
        store.record(.image(try storedImage(1)), sourceApp: nil, at: start)
        store.record(.image(try storedImage(2, size: 3000)), sourceApp: nil, at: start + 1)
        store.record(text: "abc", sourceApp: nil, at: start + 2)

        let result = store.clear()
        #expect(result == ClearResult(removedCount: 3, freedBytes: 1100 + 3100 + 3))
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func sameImageCopiedAgainKeepsTheEntryAndDeletesTheNewCopy() throws {
        let store = makeStore()
        let first = try storedImage(5)
        let id = store.record(.image(first), sourceApp: nil, at: start)
        store.record(text: "between", sourceApp: nil, at: start + 1)

        let again = try storedImage(5)
        #expect(store.record(.image(again), sourceApp: nil, at: start + 2) == id)
        #expect(store.entries.first?.content == .image(first))
        #expect(blobs.allIDs() == Set(first.blobIDs))
    }

    @Test func recordingTheSameReferenceAgainKeepsItsBlobs() throws {
        let store = makeStore()
        let image = try storedImage()
        store.record(.image(image), sourceApp: nil, at: start)
        store.record(.image(image), sourceApp: nil, at: start + 1)
        #expect(blobs.allIDs() == Set(image.blobIDs))
        #expect(store.entries.count == 1)
    }

    @Test func imageOrFilesThatTurnOutToBeASecretAreRemovedNotConcealed() throws {
        let store = makeStore()
        let imageID = store.record(.image(try storedImage()), sourceApp: nil, at: start)
        let filesID = store.record(ContentFixtures.files("/a"), sourceApp: nil, at: start + 1)
        store.record(text: "kept", sourceApp: nil, at: start + 2)

        store.conceal(id: imageID, expiresAt: start + 60)
        store.conceal(id: filesID, expiresAt: start + 60)
        #expect(store.entries.map(\.text) == ["kept"])
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func concealedRichTextIsKeptConcealed() {
        let store = makeStore()
        let id = store.record(ContentFixtures.richText("pw"), sourceApp: nil, at: start)
        store.conceal(id: id, expiresAt: start + 60)
        #expect(store.entries.first?.isConcealed == true)
    }

    @Test func imageRecordedAsASecretIsNotKept() throws {
        let store = makeStore()
        let image = try storedImage()
        store.record(.image(image), sourceApp: nil, at: start)
        store.record(text: "other", sourceApp: nil, at: start + 1)

        let id = store.record(.image(image), sourceApp: nil, at: start + 2, concealed: true, expiresAt: start + 60)
        #expect(!store.entries.contains { $0.id == id })
        #expect(store.entries.map(\.text) == ["other"])
        #expect(store.currentEntryID == nil)
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func restoringOverTheLimitDeletesTheBlobsOfWhatIsDropped() throws {
        let image = try storedImage()
        let hasher = SHA256ContentHasher()
        let entries =
            (0..<10).map { index in
                ClipboardEntry(text: "text \(index)", date: start + Double(20 - index), sourceApp: nil)
            } + [
                ClipboardEntry(
                    content: .image(image), contentHash: hasher.hash(.image(image)), date: start, sourceApp: nil)
            ]
        let store = InMemoryHistoryStore(
            restoring: entries, at: start + 30, retention: RetentionPolicy(entryLimit: 10), blobs: blobs)
        #expect(store.entries.count == 10)
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func failedBlobDeleteStillRemovesTheEntry() throws {
        let undeletable = UndeletableBlobStore()
        let store = InMemoryHistoryStore(blobs: undeletable)
        let image = try ContentFixtures.storedImage(in: undeletable)
        let id = store.record(.image(image), sourceApp: nil, at: start)
        store.remove(id: id)
        #expect(store.entries.isEmpty)
        // Left for the sweep at the next launch.
        #expect(undeletable.allIDs().count == 2)
    }
}

@MainActor
struct PersistentHistoryStoreBlobTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let disk = FakeHistoryPersistence()
    private let blobs = InMemoryBlobStore()

    private func makeStore(
        blobs: (any BlobStore)?,
        retention: RetentionPolicy = .default,
        now: Date? = nil
    ) -> PersistentHistoryStore {
        PersistentHistoryStore(
            persistence: disk, sealer: FakeSecretSealer(), savesPasswords: true, retention: retention,
            now: now ?? start, blobs: blobs)
    }

    private func makeStore(now: Date? = nil) -> PersistentHistoryStore {
        makeStore(blobs: blobs, now: now)
    }

    // Each test opens the store before writing image data, as the app does: opening sweeps blobs no record uses.

    @Test func imageSurvivesARestartWithItsBlobs() throws {
        let store = makeStore()
        let image = try ContentFixtures.storedImage(in: blobs)
        store.record(.image(image), sourceApp: nil, at: start)

        let restarted = makeStore(now: start + 1)
        #expect(restarted.entries.map(\.content) == [.image(image)])
        #expect(blobs.allIDs() == Set(image.blobIDs))
        #expect(disk.records.values.first?.blobIDs == image.blobIDs.map(\.uuid))
    }

    @Test func imageWhoseDataIsGoneIsDeletedAtLaunch() throws {
        let store = makeStore()
        let image = try ContentFixtures.storedImage(in: blobs)
        store.record(.image(image), sourceApp: nil, at: start)
        store.record(text: "text", sourceApp: nil, at: start + 1)
        blobs.delete([image.blobID])

        let restarted = makeStore(now: start + 2)
        #expect(restarted.entries.map(\.text) == ["text"])
        #expect(disk.records.count == 1)
        // Its thumbnail is no use without it.
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func blobsNoRecordReferencesAreDeletedAtLaunch() throws {
        let store = makeStore()
        let image = try ContentFixtures.storedImage(in: blobs)
        store.record(.image(image), sourceApp: nil, at: start)
        // Written for an entry that was never saved, for example because the app quit right after.
        let orphan = blobs.write(Data([1, 2, 3]))

        _ = makeStore(now: start + 1)
        #expect(blobs.allIDs() == Set(image.blobIDs))
        #expect(!blobs.contains(orphan))
    }

    @Test func nothingIsSweptWhenTheHistoryCannotBeRead() throws {
        let store = makeStore()
        let image = try ContentFixtures.storedImage(in: blobs)
        store.record(.image(image), sourceApp: nil, at: start)
        disk.failing = [.loadAll]

        _ = makeStore(now: start + 1)
        #expect(blobs.allIDs() == Set(image.blobIDs))
    }

    @Test(arguments: [HistoryPersistenceError.openFailed, .storeReset])
    func nothingIsSweptWhenTheSavedHistoryCouldNotBeOpened(error: HistoryPersistenceError) throws {
        // The history on disk could not be opened (or was moved aside), so its images may still be wanted.
        let image = try ContentFixtures.storedImage(in: blobs)
        _ = PersistentHistoryStore(
            persistence: InMemoryHistoryPersistence(), sealer: nil, savesPasswords: false, now: start,
            openError: error, blobs: blobs)
        #expect(blobs.allIDs() == Set(image.blobIDs))
    }

    @Test func withoutABlobStoreImageRecordsAreLeftOnDiskUnloaded() throws {
        let store = makeStore()
        let image = try ContentFixtures.storedImage(in: blobs)
        store.record(.image(image), sourceApp: nil, at: start)
        store.record(text: "text", sourceApp: nil, at: start + 1)

        let withoutBlobs = makeStore(blobs: nil, now: start + 2)
        #expect(withoutBlobs.entries.map(\.text) == ["text"])
        #expect(disk.records.count == 2)
        #expect(blobs.allIDs() == Set(image.blobIDs))
    }

    @Test func entriesDroppedByTheLimitsAtLaunchLoseTheirBlobs() throws {
        let store = makeStore()
        let image = try ContentFixtures.storedImage(in: blobs)
        store.record(.image(image), sourceApp: nil, at: start)
        for index in 1...10 {
            store.record(text: "text \(index)", sourceApp: nil, at: start + Double(index))
        }

        let restarted = makeStore(blobs: blobs, retention: RetentionPolicy(entryLimit: 10), now: start + 20)
        #expect(restarted.entries.count == 10)
        #expect(disk.records.count == 10)
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func sizeOnDiskIncludesTheBlobs() throws {
        disk.bytesOnDisk = 4096
        let store = makeStore()
        store.record(.image(try ContentFixtures.storedImage(in: blobs)), sourceApp: nil, at: start)
        #expect(store.storedBytes() == Int64(4096 + 1100))
    }

    @Test func sizeOnDiskIsUnknownWithoutFilesForTheRecords() throws {
        disk.bytesOnDisk = nil
        let store = makeStore()
        store.record(.image(try ContentFixtures.storedImage(in: blobs)), sourceApp: nil, at: start)
        #expect(store.storedBytes() == nil)
    }
}
