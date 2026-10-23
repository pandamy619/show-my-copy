import Foundation
import Testing

@testable import ShowMyCopy

/// When the store needs the key for saved passwords. Getting the key can show a Keychain prompt, so a history
/// without passwords must never ask for it.
@MainActor
struct PersistentHistoryStoreKeyTests {
    private let disk = FakeHistoryPersistence()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func plainHistoryNeverAsksForTheKey() {
        let earlier = disk.makeStore(now: start)
        earlier.record(text: "saved", sourceApp: nil, at: start)
        let factory = SealerFactorySpy()

        let store = disk.makeStore(sealer: factory.makeLazySealer(), now: start + 1)
        let id = store.record(text: "plain", sourceApp: nil, at: start + 2)
        store.record(text: "other", sourceApp: nil, at: start + 3)
        store.remove(id: id)
        store.setLimit(10)
        store.removeConcealed()
        store.removeExpired(at: start + 4)
        store.clear()

        #expect(factory.calls == 0)
        #expect(store.storageError == nil)
    }

    @Test func savingPasswordsAsksForTheKeyOnce() {
        let factory = SealerFactorySpy()
        let store = disk.makeStore(sealer: factory.makeLazySealer(), now: start)

        store.record(text: "plain", sourceApp: nil, at: start)
        #expect(factory.calls == 0)
        store.record(text: "hunter2", sourceApp: nil, at: start + 1, concealed: true, expiresAt: start + 600)
        store.record(text: "swordfish", sourceApp: nil, at: start + 2, concealed: true, expiresAt: start + 600)

        #expect(factory.calls == 1)
        #expect(disk.savedTexts() == ["plain", "hunter2", "swordfish"])
    }

    @Test func loadingSavedPasswordsAsksForTheKeyOnce() {
        let earlier = disk.makeStore(now: start)
        earlier.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        earlier.record(text: "swordfish", sourceApp: nil, at: start + 1, concealed: true, expiresAt: start + 600)
        let factory = SealerFactorySpy()

        let store = disk.makeStore(sealer: factory.makeLazySealer(), savesPasswords: true, now: start + 2)

        #expect(factory.calls == 1)
        #expect(store.entries.map(\.text) == ["swordfish", "hunter2"])
    }

    /// Saved passwords live an hour at most, so after a restart they have usually expired. Deleting them must not
    /// show a Keychain prompt.
    @Test func expiredSavedPasswordsAreDeletedWithoutAskingForTheKey() {
        let earlier = disk.makeStore(now: start)
        let expiredID = earlier.record(
            text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        let plainID = earlier.record(text: "plain", sourceApp: nil, at: start + 1)
        let factory = SealerFactorySpy()

        // Expiring exactly now counts as expired, as in `removeExpired(at:)`.
        let store = disk.makeStore(sealer: factory.makeLazySealer(), savesPasswords: true, now: start + 600)

        #expect(factory.calls == 0)
        #expect(store.entries.map(\.id) == [plainID])
        #expect(disk.record(expiredID) == nil)
        #expect(disk.record(plainID) != nil)
        #expect(store.storageError == nil)
    }

    @Test func savedPasswordsAreDeletedWithoutAskingForTheKeyWhenSavingThemIsOff() {
        let earlier = disk.makeStore(now: start)
        let passwordID = earlier.record(
            text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        let plainID = earlier.record(text: "plain", sourceApp: nil, at: start + 1)
        let factory = SealerFactorySpy()

        let store = disk.makeStore(sealer: factory.makeLazySealer(), savesPasswords: false, now: start + 2)

        #expect(factory.calls == 0)
        #expect(store.entries.map(\.id) == [plainID])
        #expect(disk.record(passwordID) == nil)
        #expect(disk.record(plainID) != nil)
        #expect(store.storageError == nil)
    }

    /// A newer app version may read a record differently, so it decides about that record, also with saving off.
    @Test func aPasswordFromANewerVersionIsLeftOnDiskWithoutAskingForTheKey() throws {
        let earlier = disk.makeStore(now: start)
        let id = earlier.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        var record = try #require(disk.record(id))
        record.schemaVersion = StoredEntryRecord.currentSchemaVersion + 1
        disk.records[id] = record
        let factory = SealerFactorySpy()

        let store = disk.makeStore(sealer: factory.makeLazySealer(), savesPasswords: false, now: start + 600)

        #expect(factory.calls == 0)
        #expect(store.entries.isEmpty)
        #expect(disk.record(id) == record)
    }

    @Test func withoutTheKeyPasswordsStayInMemoryAndTheKeyIsNotAskedForAgain() {
        let factory = SealerFactorySpy(fails: true)
        let store = disk.makeStore(sealer: factory.makeLazySealer(), now: start)

        store.record(text: "plain", sourceApp: nil, at: start)
        store.record(text: "hunter2", sourceApp: nil, at: start + 1, concealed: true, expiresAt: start + 600)
        store.record(text: "swordfish", sourceApp: nil, at: start + 2, concealed: true, expiresAt: start + 600)

        #expect(store.storageError == .sealFailed)
        #expect(store.entries.map(\.text) == ["swordfish", "hunter2", "plain"])
        #expect(disk.savedTexts() == ["plain"])
        #expect(factory.calls == 1)
    }
}
