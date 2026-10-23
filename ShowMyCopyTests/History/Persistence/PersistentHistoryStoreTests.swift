import Foundation
import Testing

@testable import ShowMyCopy

/// The store is created again on the same fake persistence to stand for quitting and starting the app.
@MainActor
struct PersistentHistoryStoreTests {
    private let disk = FakeHistoryPersistence()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")

    private func makeStore(
        sealer: (any SecretSealing)? = FakeSecretSealer(),
        retention: RetentionPolicy = .default,
        now: Date? = nil,
        openError: HistoryPersistenceError? = nil
    ) -> PersistentHistoryStore {
        PersistentHistoryStore(
            persistence: disk, sealer: sealer, retention: retention, now: now ?? start, openError: openError)
    }

    private func savedTexts(sealer: FakeSecretSealer = FakeSecretSealer()) -> Set<String> {
        let coder = StoredEntryCoder(sealer: sealer, hasher: SHA256ContentHasher())
        return Set(
            disk.records.values.compactMap { record in
                guard case .entry(let entry) = coder.decode(record) else {
                    return nil
                }
                return entry.text
            })
    }

    // MARK: - Across restarts

    @Test func historySurvivesARestart() throws {
        let first = makeStore()
        first.record(text: "older", sourceApp: notes, at: start)
        first.record(text: "newer", sourceApp: nil, at: start + 1)
        first.record(text: "hunter2", sourceApp: notes, at: start + 2, concealed: true, expiresAt: start + 600)

        let second = makeStore(now: start + 10)
        #expect(second.entries == first.entries)
        #expect(second.entries.map(\.text) == ["hunter2", "newer", "older"])
        #expect(second.currentEntryID == nil)
        #expect(second.storageError == nil)
        #expect(second.stats() == first.stats())
    }

    @Test func aCopyAfterARestartMovesTheSavedEntry() throws {
        let first = makeStore()
        let id = first.record(text: "hello", sourceApp: nil, at: start)
        first.record(text: "other", sourceApp: nil, at: start + 1)

        let second = makeStore()
        #expect(second.record(text: "hello", sourceApp: notes, at: start + 5) == id)
        #expect(second.entries.map(\.text) == ["hello", "other"])
        #expect(disk.records.count == 2)
        #expect(disk.record(id)?.date == start + 5)
        #expect(disk.record(id)?.sourceAppName == "Notes")
    }

    @Test func aPlainCopyAfterARestartKeepsASavedPasswordConcealed() throws {
        let first = makeStore()
        let id = first.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)

        let second = makeStore()
        #expect(second.record(text: "hunter2", sourceApp: notes, at: start + 5) == id)
        let entry = try #require(second.entries.first)
        #expect(entry.isConcealed)
        #expect(entry.expiresAt == start + 600)
        #expect(disk.record(id)?.isConcealed == true)
    }

    @Test func entriesLoadNewestFirst() {
        let first = makeStore()
        for index in 0..<5 {
            first.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
        }
        // The fake returns records oldest first.
        #expect(makeStore().entries.map(\.text) == ["item 4", "item 3", "item 2", "item 1", "item 0"])
    }

    // MARK: - Passwords on disk

    @Test func aPasswordIsSavedSealedWithoutHashOrPreview() throws {
        let store = makeStore()
        let id = store.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)

        let record = try #require(disk.record(id))
        #expect(record.isConcealed)
        #expect(record.payload.range(of: Data("hunter2".utf8)) == nil)
        #expect(record.contentHash == nil)
        #expect(record.previewText == nil)
        #expect(record.expiresAt == start + 600)
    }

    @Test func concealingAnEntryReplacesItsPlainRecord() throws {
        let store = makeStore()
        let id = store.record(text: "hunter2", sourceApp: nil, at: start)
        #expect(disk.record(id)?.payload == Data("hunter2".utf8))

        store.conceal(id: id, expiresAt: start + 60)
        let record = try #require(disk.record(id))
        #expect(record.isConcealed)
        #expect(record.payload.range(of: Data("hunter2".utf8)) == nil)
        #expect(record.contentHash == nil)
        #expect(record.previewText == nil)
    }

    @Test func limitExpiryIsSaved() {
        let store = makeStore()
        let id = store.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 3600)
        store.limitExpiry(to: start + 60)
        #expect(disk.record(id)?.expiresAt == start + 60)
    }

    @Test func withoutSealerPasswordsStayInMemoryOnly() {
        let store = makeStore(sealer: nil)
        store.record(text: "plain", sourceApp: nil, at: start)
        store.record(text: "hunter2", sourceApp: nil, at: start + 1, concealed: true, expiresAt: start + 600)

        #expect(store.entries.count == 2)
        #expect(savedTexts() == ["plain"])
        #expect(store.storageError == nil)
    }

    @Test func withoutSealerConcealingDeletesThePlainRecord() {
        let store = makeStore(sealer: nil)
        let id = store.record(text: "hunter2", sourceApp: nil, at: start)
        store.conceal(id: id, expiresAt: start + 60)

        #expect(store.entries.first?.isConcealed == true)
        #expect(disk.record(id) == nil)
    }

    @Test func withoutSealerSavedPasswordsAreDeletedOnLoad() {
        makeStore().record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        makeStore().record(text: "plain", sourceApp: nil, at: start + 1)

        let store = makeStore(sealer: nil)
        #expect(store.entries.map(\.text) == ["plain"])
        #expect(disk.records.count == 1)
    }

    @Test func aPasswordThatCannotBeSealedStaysInMemoryAndIsReported() {
        let store = makeStore(sealer: FakeSecretSealer(failsToSeal: true))
        let id = store.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)

        #expect(store.entries.map(\.id) == [id])
        #expect(disk.record(id) == nil)
        #expect(store.storageError == .sealFailed)
    }

    @Test func aRecordThatCannotBeOpenedIsDroppedAndDeleted() {
        let other = PersistentHistoryStore(persistence: disk, sealer: FakeSecretSealer(key: 0x11), now: start)
        let lostID = other.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        let plainID = other.record(text: "plain", sourceApp: nil, at: start + 1)

        let store = makeStore()
        #expect(store.entries.map(\.id) == [plainID])
        #expect(disk.record(lostID) == nil)
        #expect(disk.record(plainID) != nil)
    }

    @Test func aRecordFromANewerVersionIsLeftOnDisk() throws {
        let id = makeStore().record(text: "future", sourceApp: nil, at: start)
        let record = try #require(disk.record(id))
        disk.records[id] = record.replacingKind(with: "hologram")

        #expect(makeStore().entries.isEmpty)
        #expect(disk.record(id) != nil)
    }

    // MARK: - Removing on load

    @Test func expiredPasswordsAreRemovedOnLoad() {
        let first = makeStore()
        first.record(text: "plain", sourceApp: nil, at: start)
        let expiredID = first.record(
            text: "hunter2", sourceApp: nil, at: start + 1, concealed: true, expiresAt: start + 60)
        let laterID = first.record(
            text: "s3cret", sourceApp: nil, at: start + 2, concealed: true, expiresAt: start + 600)

        let second = makeStore(now: start + 60)
        #expect(second.entries.map(\.text) == ["s3cret", "plain"])
        #expect(disk.record(expiredID) == nil)
        #expect(disk.record(laterID) != nil)
    }

    @Test func retentionIsAppliedOnLoad() {
        let first = makeStore(retention: RetentionPolicy(entryLimit: 20))
        for index in 0..<15 {
            first.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
        }

        let second = makeStore(retention: RetentionPolicy(entryLimit: 10))
        #expect(second.entries.count == 10)
        #expect(second.entries.last?.text == "item 5")
        #expect(disk.records.count == 10)
        #expect(!savedTexts().contains("item 4"))
    }

    @Test func expiredPasswordsAreRemovedBeforeTheLimitIsApplied() {
        let first = makeStore(retention: RetentionPolicy(entryLimit: 20))
        for index in 0..<10 {
            first.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
        }
        first.record(text: "hunter2", sourceApp: nil, at: start + 10, concealed: true, expiresAt: start + 60)

        let second = makeStore(retention: RetentionPolicy(entryLimit: 10), now: start + 100)
        #expect(second.entries.count == 10)
        #expect(second.entries.last?.text == "item 0")
    }

    @Test func nothingIsWrittenOnLoadWhenNothingIsRemoved() {
        let first = makeStore()
        first.record(text: "a", sourceApp: nil, at: start)
        disk.resetCalls()

        _ = makeStore()
        #expect(disk.calls == [.loadAll])
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
        // Also records this version could not load.
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
        disk.failing = [.insert]
        let id = store.record(text: "a", sourceApp: nil, at: start)

        #expect(store.entries.map(\.id) == [id])
        #expect(store.currentEntryID == id)
        #expect(store.storageError == .saveFailed)
        #expect(disk.records.isEmpty)
    }

    @Test func theNextChangeAfterAFailedWriteSavesEverything() {
        let store = makeStore()
        disk.failing = [.insert]
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
        disk.failing = [.delete]
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
        disk.failing = [.deleteAll]

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
