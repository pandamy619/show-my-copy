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
        disk.makeStore(sealer: sealer, retention: retention, now: now ?? start, openError: openError)
    }

    private func savedTexts() -> Set<String> {
        disk.savedTexts()
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
        #expect(disk.record(id)?.payload == Data([StoredPayload.format]) + Data("hunter2".utf8))

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
        let other = disk.makeStore(sealer: FakeSecretSealer(key: 0x11), now: start)
        let lostID = other.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        let plainID = other.record(text: "plain", sourceApp: nil, at: start + 1)

        let store = makeStore()
        #expect(store.entries.map(\.id) == [plainID])
        #expect(disk.record(lostID) == nil)
        #expect(disk.record(plainID) != nil)
    }

    @Test func aRecordOfAnUnknownKindIsDeleted() throws {
        let id = makeStore().record(text: "hologram", sourceApp: nil, at: start)
        let record = try #require(disk.record(id))
        disk.records[id] = record.replacingKind(with: "hologram")

        #expect(makeStore().entries.isEmpty)
        #expect(disk.record(id) == nil)
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
}
