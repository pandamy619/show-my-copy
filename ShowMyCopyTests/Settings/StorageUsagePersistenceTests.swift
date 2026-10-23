import Foundation
import Observation
import Synchronization
import Testing

@testable import ShowMyCopy

private struct NoMemoryReader: MemoryUsageReading {
    func residentBytes() -> UInt64? { nil }
}

/// Set from an observation callback, which may run on any thread.
private final class ChangeFlag: Sendable {
    private let isSet = Mutex(false)

    var value: Bool {
        isSet.withLock { $0 }
    }

    func set() {
        isSet.withLock { $0 = true }
    }
}

/// What the Storage settings show about the history saved on disk.
@MainActor
struct StorageUsagePersistenceTests {
    private let disk = FakeHistoryPersistence()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeUsage(_ history: any HistoryStore) -> StorageUsage {
        StorageUsage(history: history, memoryReader: NoMemoryReader())
    }

    // MARK: - Warnings

    @Test func historyInMemoryHasNoWarningAndNoDiskSize() {
        let usage = makeUsage(ClipboardHistory())
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
        disk.failing = [.insert]
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
        disk.failing = [.insert]
        store.record(text: "a", sourceApp: nil, at: start)
        #expect(changed.value)
    }

    // MARK: - Size on disk

    @Test func diskSizeComesFromTheStoreFiles() {
        disk.bytesOnDisk = 32_768
        let usage = makeUsage(disk.makeStore(now: start))
        #expect(usage.diskBytes == 32_768)
    }

    @Test func historyThatIsNotSavedHasNoDiskSize() {
        disk.bytesOnDisk = nil
        let usage = makeUsage(disk.makeStore(now: start))
        #expect(usage.diskBytes == nil)
    }

    @Test func diskSizeIsReadAgainOnlyAfterTheHistoryChanges() {
        disk.bytesOnDisk = 4096
        let store = disk.makeStore(now: start)
        let usage = makeUsage(store)
        #expect(usage.diskBytes == 4096)
        #expect(usage.diskBytes == 4096)
        #expect(disk.storedBytesReadCount == 1)

        disk.bytesOnDisk = 8192
        store.record(text: "a", sourceApp: nil, at: start)
        #expect(usage.diskBytes == 8192)
        #expect(disk.storedBytesReadCount == 2)
    }

    @Test func refreshingReadsTheDiskSizeAgainAndNotifiesViews() {
        disk.bytesOnDisk = 4096
        let usage = makeUsage(disk.makeStore(now: start))
        #expect(usage.diskBytes == 4096)

        let changed = ChangeFlag()
        withObservationTracking {
            _ = usage.diskBytes
        } onChange: {
            changed.set()
        }
        disk.bytesOnDisk = 12_288
        usage.refreshDiskBytes()

        #expect(changed.value)
        #expect(usage.diskBytes == 12_288)
        #expect(disk.storedBytesReadCount == 2)
    }
}
