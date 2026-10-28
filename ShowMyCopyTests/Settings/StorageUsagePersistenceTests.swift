import Foundation
import Observation
import Synchronization
import Testing

@testable import ShowMyCopy

/// What the Storage settings show about the history saved on disk.
@MainActor
struct StorageUsagePersistenceTests {
    private let disk = FakeHistoryPersistence()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeUsage(_ store: PersistentHistoryStore) -> StorageUsage {
        StorageUsage(history: AppHistory(store), memoryReader: NoMemoryUsage())
    }

    // MARK: - Warnings

    @Test func historyInMemoryHasNoWarningAndNoDiskSize() {
        let usage = StorageUsage(history: .unsaved(), memoryReader: NoMemoryUsage())
        #expect(usage.storageWarning == nil)
        #expect(usage.diskBytes == nil)
    }

    @Test func savedHistoryWithoutProblemsHasNoWarning() {
        let usage = makeUsage(disk.makeStore(now: start))
        #expect(usage.storageWarning == nil)
    }

    @Test(arguments: [
        (HistoryPersistenceError.openFailed, StorageWarning.notSaved),
        (.storeReset, .historyReset),
        (.loadFailed, .historyNotLoaded),
        (.saveFailed, .changesNotSaved),
        (.sealFailed, .passwordsNotSaved),
    ])
    func everyStorageErrorHasAWarning(error: HistoryPersistenceError, warning: StorageWarning) {
        #expect(StorageWarning(error) == warning)
        let usage = makeUsage(disk.makeStore(now: start, openError: error))
        #expect(usage.storageWarning == warning)
    }

    @Test func failedSaveShowsAWarningUntilSavingWorksAgain() {
        let store = disk.makeStore(now: start)
        let usage = makeUsage(store)
        disk.failing = [.apply]
        store.record(text: "a", sourceApp: nil, at: start)
        #expect(usage.storageWarning == .changesNotSaved)

        disk.failing = []
        store.record(text: "b", sourceApp: nil, at: start + 1)
        #expect(usage.storageWarning == nil)
    }

    @Test func passwordThatCannotBeEncryptedShowsAWarning() {
        let store = disk.makeStore(sealer: FakeSecretSealer(failsToSeal: true), now: start)
        let usage = makeUsage(store)
        store.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        #expect(usage.storageWarning == .passwordsNotSaved)
    }

    @Test func viewsReadingTheWarningSeeItChange() {
        let store = disk.makeStore(now: start)
        let usage = makeUsage(store)
        let changed = ChangeFlag()
        withObservationTracking {
            _ = usage.storageWarning
        } onChange: {
            changed.set()
        }
        disk.failing = [.apply]
        store.record(text: "a", sourceApp: nil, at: start)
        #expect(changed.value)
    }

    // MARK: - Size on disk

    @Test func diskSizeComesFromTheStoreFiles() async {
        disk.bytesOnDisk = 32_768
        let usage = makeUsage(disk.makeStore(now: start))
        #expect(usage.diskBytes == nil)
        await usage.refreshDiskBytes()
        #expect(usage.diskBytes == 32_768)
    }

    @Test func historyThatIsNotSavedHasNoDiskSize() async {
        disk.bytesOnDisk = nil
        let usage = makeUsage(disk.makeStore(now: start))
        await usage.refreshDiskBytes()
        #expect(usage.diskBytes == nil)
    }

    /// Settings read the size on disk without touching the file system on the main thread, and only when asked:
    /// reading `diskBytes`, in a view update or after a change, reads nothing.
    @Test func diskSizeIsMeasuredOffTheMainThreadAndOnlyWhenAsked() async {
        disk.bytesOnDisk = 4096
        let store = disk.makeStore(now: start)
        let usage = makeUsage(store)
        await usage.refreshDiskBytes()
        #expect(usage.diskBytes == 4096)
        #expect(usage.diskBytes == 4096)
        disk.bytesOnDisk = 8192
        store.record(text: "a", sourceApp: nil, at: start)
        #expect(usage.diskBytes == 4096)
        #expect(disk.storedBytesReadCount == 1)

        await usage.refreshDiskBytes()
        #expect(usage.diskBytes == 8192)
        #expect(disk.storedBytesReadCount == 2)
        #expect(disk.storedBytesReadsOnMainThread == 0)
    }

    @Test func refreshingNotifiesViews() async {
        disk.bytesOnDisk = 4096
        let usage = makeUsage(disk.makeStore(now: start))
        await usage.refreshDiskBytes()

        let changed = ChangeFlag()
        withObservationTracking {
            _ = usage.diskBytes
        } onChange: {
            changed.set()
        }
        disk.bytesOnDisk = 12_288
        await usage.refreshDiskBytes(recountingImages: true)

        #expect(changed.value)
        #expect(usage.diskBytes == 12_288)
    }

    /// The saved images are counted from the blob store's running total after a change, and counted again from the
    /// disk only when asked (when the settings open).
    @Test func imagesAreCountedFromARunningTotalAndRecountedWhenAsked() async throws {
        disk.bytesOnDisk = 0
        let files = ListingCountingBlobStore()
        let blobs = MeasuredBlobStore(base: files)
        let store = disk.makeStore(now: start, blobs: blobs)
        let usage = makeUsage(store)
        await usage.refreshDiskBytes(recountingImages: true)
        let listings = files.listings

        store.record(.image(try ContentFixtures.storedImage(in: blobs)), sourceApp: nil, at: start)
        await usage.refreshDiskBytes()
        #expect(usage.diskBytes == 1100)
        #expect(files.listings == listings)

        await usage.refreshDiskBytes(recountingImages: true)
        #expect(usage.diskBytes == 1100)
        #expect(files.listings == listings + 1)
    }
}
