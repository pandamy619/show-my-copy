import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct PersistentHistoryStoreBlobTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let disk = FakeHistoryPersistence()
    private let blobs = InMemoryBlobStore()

    private func makeStore(
        blobs: (any BlobStore)?,
        retention: RetentionPolicy = .default,
        now: Date? = nil,
        leftovers: (any HistoryLeftovers)? = nil
    ) -> PersistentHistoryStore {
        PersistentHistoryStore.loadedNow(
            persistence: disk, sealer: FakeSecretSealer(), savesPasswords: true, retention: retention,
            now: now ?? start, blobs: blobs, leftovers: leftovers)
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
        let orphan = try blobs.write(Data([1, 2, 3]))

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
        _ = PersistentHistoryStore.loadedNow(
            persistence: InMemoryHistoryPersistence(), sealer: nil, savesPasswords: false, now: start,
            openError: error, blobs: blobs)
        #expect(blobs.allIDs() == Set(image.blobIDs))
    }

    /// A copy of a history that could not be opened may reference any image, so no image is an orphan while it is
    /// kept: not at the launch that moved it aside, and not at the launches after.
    @Test func nothingIsSweptWhileACopyOfAnUnreadableHistoryIsKept() throws {
        let leftovers = FakeHistoryLeftovers()
        let image = try ContentFixtures.storedImage(in: blobs)

        _ = makeStore(blobs: blobs, now: start, leftovers: leftovers)
        _ = makeStore(blobs: blobs, now: start + 1, leftovers: leftovers)
        #expect(blobs.allIDs() == Set(image.blobIDs))

        leftovers.hasDamagedCopy = false
        _ = makeStore(blobs: blobs, now: start + 2, leftovers: leftovers)
        #expect(blobs.allIDs().isEmpty)
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

    @Test func sizeOnDiskIncludesTheBlobs() async throws {
        disk.bytesOnDisk = 4096
        let store = makeStore()
        store.record(.image(try ContentFixtures.storedImage(in: blobs)), sourceApp: nil, at: start)
        #expect(await store.storedBytes(recountingBlobs: false) == Int64(4096 + 1100))
        #expect(await store.storedBytes(recountingBlobs: true) == Int64(4096 + 1100))
    }

    @Test func sizeOnDiskIsUnknownWithoutFilesForTheRecords() async throws {
        disk.bytesOnDisk = nil
        let store = makeStore()
        store.record(.image(try ContentFixtures.storedImage(in: blobs)), sourceApp: nil, at: start)
        #expect(await store.storedBytes(recountingBlobs: false) == nil)
    }

    @Test func sizeOnDiskIsMeasuredOffTheMainThread() async {
        disk.bytesOnDisk = 4096
        let store = makeStore()
        _ = await store.storedBytes(recountingBlobs: true)
        #expect(disk.storedBytesReadCount == 1)
        #expect(disk.storedBytesReadsOnMainThread == 0)
    }
}
