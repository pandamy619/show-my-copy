import Foundation
import Observation
import Testing

@testable import ShowMyCopy

/// Writing each change, and what happens when writing fails.
@MainActor
struct PersistentHistoryStoreWriteTests {
    private let disk = FakeHistoryPersistence()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")

    private func makeStore(
        sealer: (any SecretSealing)? = FakeSecretSealer(),
        retention: RetentionPolicy = .default,
        now: Date? = nil,
        openError: HistoryPersistenceError? = nil
    ) -> PersistentHistoryStore {
        disk.makeStore(sealer: sealer, retention: retention, now: now ?? start, openError: openError)
    }

    private func savedTexts() -> Set<String> {
        disk.savedTexts()
    }

    // MARK: - Changes reach the disk

    @Test func trimmingOnRecordDeletesTheOldestRecord() {
        let store = makeStore(retention: RetentionPolicy(entryLimit: 10))
        for index in 0..<11 {
            store.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
        }
        #expect(disk.records.count == 10)
        #expect(!savedTexts().contains("item 0"))
    }

    @Test func lowerLimitDeletesRecords() {
        let store = makeStore(retention: RetentionPolicy(entryLimit: 20))
        for index in 0..<15 {
            store.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
        }
        store.setLimit(10)
        #expect(disk.records.count == 10)
    }

    @Test func removeDeletesTheRecord() {
        let store = makeStore()
        let id = store.record(text: "a", sourceApp: nil, at: start)
        store.record(text: "b", sourceApp: nil, at: start + 1)
        store.remove(id: id)
        #expect(savedTexts() == ["b"])
    }

    @Test func removeConcealedDeletesSavedPasswords() {
        let store = makeStore()
        store.record(text: "plain", sourceApp: nil, at: start)
        store.record(text: "hunter2", sourceApp: nil, at: start + 1, concealed: true, expiresAt: start + 600)
        store.removeConcealed()

        #expect(disk.records.count == 1)
        #expect(savedTexts() == ["plain"])
        #expect(makeStore().entries.map(\.text) == ["plain"])
    }

    @Test func removeExpiredDeletesSavedPasswords() {
        let store = makeStore()
        store.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)
        store.removeExpired(at: start + 60)
        #expect(disk.records.isEmpty)
    }

    @Test func clearDeletesEverythingOnDisk() throws {
        let store = makeStore()
        store.record(text: "a", sourceApp: nil, at: start)
        store.record(text: "hunter2", sourceApp: nil, at: start + 1, concealed: true, expiresAt: start + 600)
        // Also records it did not load, such as images while there was no blob store.
        disk.records[UUID()] = try #require(disk.records.values.first).replacingKind(with: "hologram")

        #expect(store.clear() == ClearResult(removedCount: 2, freedBytes: 8))
        #expect(disk.records.isEmpty)
        #expect(makeStore().entries.isEmpty)
    }

    @Test func callsThatChangeNothingWriteNothing() {
        let store = makeStore()
        store.record(text: "a", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        disk.resetCalls()

        store.removeExpired(at: start + 1)
        store.markCurrentSkipped()
        store.markNewestCurrent(ifItHolds: .text("a"))
        store.setRetention(store.retention)
        store.remove(id: UUID())
        #expect(disk.calls.isEmpty)
    }

    // MARK: - Failures

    @Test func aFailedWriteKeepsTheEntryAndIsReported() {
        let store = makeStore()
        disk.failing = [.apply]
        let id = store.record(text: "a", sourceApp: nil, at: start)

        #expect(store.entries.map(\.id) == [id])
        #expect(store.currentEntryID == id)
        #expect(store.storageError == .saveFailed)
        #expect(disk.records.isEmpty)
    }

    @Test func theNextChangeAfterAFailedWriteSavesEverything() {
        let store = makeStore()
        disk.failing = [.apply]
        store.record(text: "a", sourceApp: nil, at: start)
        disk.failing = []

        store.record(text: "b", sourceApp: nil, at: start + 1)
        #expect(store.storageError == nil)
        #expect(savedTexts() == ["a", "b"])
    }

    @Test func aFailedDeleteIsMadeGoodByTheNextChange() {
        let store = makeStore()
        store.record(text: "plain", sourceApp: nil, at: start)
        store.record(text: "hunter2", sourceApp: nil, at: start + 1, concealed: true, expiresAt: start + 600)
        disk.failing = [.apply]
        store.removeConcealed()
        #expect(store.storageError == .saveFailed)
        disk.failing = []

        store.record(text: "next", sourceApp: nil, at: start + 2)
        #expect(savedTexts() == ["plain", "next"])
        #expect(store.storageError == nil)
    }

    @Test func aFailedClearIsReported() {
        let store = makeStore()
        store.record(text: "a", sourceApp: nil, at: start)
        disk.failing = [.apply]

        #expect(store.clear() == ClearResult(removedCount: 1, freedBytes: 1))
        #expect(store.entries.isEmpty)
        #expect(store.storageError == .saveFailed)
    }

    @Test func aFailedLoadStartsEmptyAndLeavesTheDiskAlone() {
        makeStore().record(text: "a", sourceApp: nil, at: start)
        disk.failing = [.loadAll]
        disk.resetCalls()

        let store = makeStore()
        #expect(store.entries.isEmpty)
        #expect(store.storageError == .loadFailed)
        #expect(disk.calls == [.loadAll])

        // A later write does not hide that the saved history could not be read.
        store.record(text: "b", sourceApp: nil, at: start + 1)
        #expect(store.storageError == .loadFailed)
        #expect(disk.records.count == 2)
    }

    @Test func anErrorFromOpeningTheStoreIsReported() {
        #expect(makeStore(openError: .openFailed).storageError == .openFailed)
    }

    @Test func observersSeeEntriesAndStorageErrors() {
        let store = makeStore()
        let entriesChanged = ObservedChange()
        withObservationTracking {
            _ = store.entries
        } onChange: {
            entriesChanged.set()
        }
        let errorChanged = ObservedChange()
        withObservationTracking {
            _ = store.storageError
        } onChange: {
            errorChanged.set()
        }

        disk.failing = [.apply]
        store.record(text: "a", sourceApp: nil, at: start)
        #expect(entriesChanged.value)
        #expect(errorChanged.value)
    }

    // MARK: - Launch

    @Test func theFirstPollAfterARestartLeavesTheSavedNewestEntryAsItIs() throws {
        let first = makeStore()
        first.record(text: "older", sourceApp: notes, at: start)
        first.record(text: "copied yesterday", sourceApp: notes, at: start + 1)

        let store = makeStore(now: start + 100)
        let before = try #require(store.entries.first)
        disk.resetCalls()
        let pasteboard = FakePasteboard()
        pasteboard.copy("copied yesterday")
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            history: store,
            frontmostApp: { nil },
            now: { [start] in start + 100 },
            passwordPolicy: { .default }
        )

        monitor.poll()
        #expect(store.entries.first == before)
        #expect(store.currentEntryID == before.id)
        #expect(disk.calls.isEmpty)
    }
}

/// Set from an observation callback, which may run on any thread.
private final class ObservedChange: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var value: Bool {
        lock.withLock { isSet }
    }

    func set() {
        lock.withLock { isSet = true }
    }
}
