import Foundation
import Testing

@testable import ShowMyCopy

/// Saved passwords while the key cannot be used now (not loaded yet, the Mac is locked, access was denied): they
/// stay on disk unopened and are opened once the key loads, and only data that a loaded key cannot open is deleted.
@MainActor
struct PersistentHistoryStorePasswordKeyTests {
    private let disk = FakeHistoryPersistence()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// Saves a password and a plain entry, as a session before this one did. Returns the password's ID.
    @discardableResult
    private func savePassword(_ text: String = "hunter2", at date: Date? = nil, expiresAt: Date? = nil) -> UUID {
        let date = date ?? start
        let earlier = disk.makeStore(now: date)
        return earlier.record(
            text: text, sourceApp: nil, at: date, concealed: true, expiresAt: expiresAt ?? date + 600)
    }

    nonisolated static let keyErrors: [SecretSealingError] = [
        .keyNotLoaded,
        .keyUnavailable(.accessDenied),
        .keyUnavailable(.interactionNotAllowed),
        .keyUnavailable(.missingEntitlement),
        .keyUnavailable(.unexpectedItemData),
        .keyUnavailable(.unexpectedStatus(-25_293)),
        .invalidKeyLength(16),
    ]

    @Test(arguments: keyErrors)
    func savedPasswordsStayOnDiskUnopenedWhileTheKeyCannotBeUsed(_ error: SecretSealingError) {
        let passwordID = savePassword()
        let plainID = disk.makeStore(now: start).record(text: "plain", sourceApp: nil, at: start + 1)
        let saved = disk.records
        disk.resetCalls()

        let store = disk.makeStore(sealer: KeyTroubleSealer(failure: error), now: start + 2)

        #expect(store.entries.map(\.id) == [plainID])
        #expect(disk.records == saved)
        #expect(disk.changes.isEmpty)
        #expect(disk.record(passwordID) != nil)
        #expect(store.storageError == nil)
    }

    nonisolated static let dataErrors: [SecretSealingError] = [.authenticationFailed, .missingFormatVersion]

    @Test(arguments: dataErrors)
    func savedPasswordsALoadedKeyCannotOpenAreDeleted(_ error: SecretSealingError) {
        let passwordID = savePassword()

        let store = disk.makeStore(sealer: DataTroubleSealer(error: error), now: start + 2)

        #expect(store.entries.isEmpty)
        #expect(disk.record(passwordID) == nil)
    }

    @Test func savedPasswordsAreOpenedOnceTheKeyLoads() async {
        let olderID = disk.makeStore(now: start).record(text: "older", sourceApp: nil, at: start)
        let passwordID = savePassword(at: start + 1)
        let newerID = disk.makeStore(now: start).record(text: "newer", sourceApp: nil, at: start + 2)
        let saved = disk.records
        let sealer = KeyTroubleSealer()
        let store = disk.makeStore(sealer: sealer, now: start + 3)
        #expect(store.entries.map(\.id) == [newerID, olderID])

        await store.loadPasswordKey()

        #expect(store.entries.map(\.id) == [newerID, passwordID, olderID])
        #expect(store.entries.map(\.text) == ["newer", "hunter2", "older"])
        #expect(store.entries[1].isConcealed)
        #expect(disk.records == saved)
        #expect(sealer.loadCount == 1)
        #expect(store.storageError == nil)
    }

    @Test func savedPasswordsStayUnopenedWhileTheKeyStaysUnavailable() async {
        let passwordID = savePassword()
        let saved = disk.records
        let sealer = KeyTroubleSealer(failure: .keyUnavailable(.interactionNotAllowed), loadedState: .lockedOut)
        let store = disk.makeStore(sealer: sealer, now: start + 1)

        await store.loadPasswordKey()
        #expect(store.entries.isEmpty)
        #expect(disk.records == saved)

        // Unlocked: the next try opens them.
        sealer.setLoadedState(.ready)
        await store.loadPasswordKey()
        #expect(store.entries.map(\.id) == [passwordID])
        #expect(disk.records == saved)
    }

    @Test func savedPasswordsALoadedKeyCannotOpenAreDeletedWhenOpenedLater() async throws {
        let keptID = savePassword(at: start + 1)
        // Sealed with another key, as by a key that was replaced.
        let otherKey = StoredEntryCoder(sealer: FakeSecretSealer(key: 0x11), hasher: SHA256ContentHasher())
        let lost = ClipboardEntry(
            text: "lost", date: start, sourceApp: nil, isConcealed: true, expiresAt: start + 600)
        try disk.insert([try #require(try otherKey.record(for: lost))])
        let lostID = lost.id
        let store = disk.makeStore(sealer: KeyTroubleSealer(), now: start + 2)
        #expect(disk.record(lostID) != nil)

        await store.loadPasswordKey()

        #expect(store.entries.map(\.id) == [keptID])
        #expect(disk.record(lostID) == nil)
        #expect(disk.record(keptID) != nil)
    }

    @Test func nothingAsksForTheKeyWhenNoPasswordWaitsForIt() async {
        disk.makeStore(now: start).record(text: "plain", sourceApp: nil, at: start)
        let sealer = KeyTroubleSealer()
        let store = disk.makeStore(sealer: sealer, now: start + 1)

        await store.loadPasswordKey()

        #expect(sealer.loadCount == 0)
        #expect(store.entries.map(\.text) == ["plain"])
    }

    // MARK: - What still applies to passwords that are not opened

    @Test func unopenedPasswordsExpireOnTime() async {
        let expiringID = savePassword("soon", expiresAt: start + 60)
        let laterID = savePassword("later", at: start + 1, expiresAt: start + 600)
        let sealer = KeyTroubleSealer()
        let store = disk.makeStore(sealer: sealer, now: start + 2)

        store.removeExpired(at: start + 60)

        #expect(disk.record(expiringID) == nil)
        #expect(disk.record(laterID) != nil)
        await store.loadPasswordKey()
        #expect(store.entries.map(\.id) == [laterID])
    }

    @Test func turningSavePasswordsOffDeletesUnopenedPasswords() async {
        let passwordID = savePassword()
        let plainID = disk.makeStore(now: start).record(text: "plain", sourceApp: nil, at: start + 1)
        let sealer = KeyTroubleSealer()
        let store = disk.makeStore(sealer: sealer, now: start + 2)

        store.removeConcealed()

        #expect(disk.record(passwordID) == nil)
        #expect(disk.record(plainID) != nil)
        await store.loadPasswordKey()
        #expect(store.entries.map(\.id) == [plainID])
        #expect(sealer.loadCount == 0)
    }

    @Test func clearHistoryDeletesUnopenedPasswords() async {
        savePassword()
        let sealer = KeyTroubleSealer()
        let store = disk.makeStore(sealer: sealer, now: start + 1)

        store.clear()

        #expect(disk.records.isEmpty)
        await store.loadPasswordKey()
        #expect(store.entries.isEmpty)
        #expect(disk.records.isEmpty)
    }

    @Test func aShorterLifetimeAppliesToUnopenedPasswords() async {
        let passwordID = savePassword(expiresAt: start + 3600)
        let store = disk.makeStore(sealer: KeyTroubleSealer(), now: start + 1)

        store.limitExpiry(to: start + 60)

        #expect(disk.record(passwordID)?.expiresAt == start + 60)
        store.removeExpired(at: start + 60)
        #expect(disk.record(passwordID) == nil)
    }

    @Test func anUnopenedPasswordWhoseDeletionFailedIsDeletedWithTheNextWrite() {
        let passwordID = savePassword()
        let store = disk.makeStore(sealer: KeyTroubleSealer(), now: start + 1)
        disk.failing = [.apply]

        store.removeConcealed()
        #expect(disk.record(passwordID) != nil)
        #expect(store.storageError == .saveFailed)

        disk.failing = []
        store.record(text: "next", sourceApp: nil, at: start + 2)
        #expect(disk.record(passwordID) == nil)
        #expect(store.storageError == nil)
    }

    @Test func aSavedPasswordCopiedAgainBeforeTheKeyLoadsIsKeptOnce() async {
        let savedID = savePassword()
        let sealer = KeyTroubleSealer()
        let store = disk.makeStore(sealer: sealer, now: start + 1)
        let copiedID = store.record(
            text: "hunter2", sourceApp: nil, at: start + 2, concealed: true, expiresAt: start + 602)

        await store.loadPasswordKey()

        #expect(store.entries.map(\.id) == [copiedID])
        #expect(disk.record(savedID) == nil)
        #expect(disk.record(copiedID) != nil)
    }

    // MARK: - Passwords copied before the key is loaded

    @Test func aPasswordCopiedBeforeTheKeyLoadsIsSavedOnceItLoads() async {
        let sealer = KeyTroubleSealer()
        let store = disk.makeStore(sealer: sealer, now: start)

        let id = store.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        #expect(disk.record(id) == nil)

        await store.loadPasswordKey()

        #expect(disk.record(id) != nil)
        #expect(disk.savedTexts() == ["hunter2"])
        #expect(store.storageError == nil)
        #expect(sealer.loadCount >= 1)
    }

    @Test func aPasswordCopiedWhileTheKeyIsUnavailableStaysInMemoryAndIsReported() async {
        let sealer = KeyTroubleSealer(failure: .keyUnavailable(.accessDenied), loadedState: .unavailable)
        let store = disk.makeStore(sealer: sealer, now: start)

        let id = store.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        await store.loadPasswordKey()

        #expect(store.entries.map(\.id) == [id])
        #expect(disk.record(id) == nil)
        #expect(store.storageError == .sealFailed)
    }
}
