import Foundation
import Testing

@testable import ShowMyCopy

/// Pins on disk: saved in the record's existing fields, across a relaunch, through a failed write, and what Clear
/// History leaves when it keeps pinned entries.
@MainActor
struct PersistentHistoryStorePinTests {
    private let disk = FakeHistoryPersistence()
    private let blobs = InMemoryBlobStore()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let clock = ManualDate(Date(timeIntervalSince1970: 1_790_000_000))

    /// A store on `disk` with `clock`; making another one stands for quitting and starting the app.
    private func makeStore(
        sealer: (any SecretSealing)? = FakeSecretSealer(),
        blobs: (any BlobStore)? = nil,
        openError: HistoryPersistenceError? = nil,
        persistence: (any HistoryPersistence)? = nil,
        leftovers: (any HistoryLeftovers)? = nil
    ) -> PersistentHistoryStore {
        PersistentHistoryStore.loadedNow(
            persistence: persistence ?? disk, sealer: sealer, savesPasswords: true, now: clock.now, clock: clock.read,
            openError: openError, blobs: blobs, leftovers: leftovers)
    }

    @Test func pinsAndTheirOrderSurviveARelaunch() throws {
        let first = makeStore()
        let older = first.record(text: "older", sourceApp: nil, at: start - 20)
        let newer = first.record(text: "newer", sourceApp: nil, at: start - 10)
        first.record(text: "plain", sourceApp: nil, at: start - 5)
        clock.now = start + 1
        first.setPinned(true, id: newer)
        clock.now = start + 2
        first.setPinned(true, id: older)

        let second = makeStore()

        #expect(second.entries == first.entries)
        #expect(second.entries.filter(\.isPinned).map(\.text) == ["older", "newer"])
        // The pin is the record's `isPinned` and its place the record's date: the saved format is the same.
        let record = try #require(disk.record(older))
        #expect(record.isPinned)
        #expect(record.date == start + 2)
    }

    @Test func aPinThatCouldNotBeSavedIsSavedWithTheNextChange() throws {
        let store = makeStore()
        let id = store.record(text: "pinned", sourceApp: nil, at: start)
        disk.failing = [.apply]

        store.setPinned(true, id: id)
        #expect(store.storageError == .saveFailed)
        #expect(disk.record(id)?.isPinned == false)
        #expect(store.entries.first?.isPinned == true)

        disk.failing = []
        store.record(text: "next", sourceApp: nil, at: start + 1)
        #expect(disk.record(id)?.isPinned == true)
        #expect(store.storageError == nil)
    }

    @Test func clearKeepingPinnedSavesThePinnedAndDeletesTheOthers() {
        let store = makeStore()
        let pinned = store.record(text: "pinned", sourceApp: nil, at: start)
        store.setPinned(true, id: pinned)
        store.record(text: "other", sourceApp: nil, at: start + 1)

        store.clear(keepingPinned: true)

        #expect(Set(disk.records.keys) == [pinned])
        #expect(makeStore().entries.map(\.id) == [pinned])
    }

    @Test func clearKeepingPinnedDeletesSavedPasswordsWaitingForTheKey() {
        let password = makeStore().record(
            text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        clock.now = start + 1
        let store = makeStore(sealer: KeyTroubleSealer())
        let pinned = store.record(text: "pinned", sourceApp: nil, at: start + 1)
        store.setPinned(true, id: pinned)
        #expect(disk.record(password) != nil)

        store.clear(keepingPinned: true)

        #expect(Set(disk.records.keys) == [pinned])
    }

    @Test func clearKeepingPinnedLeavesRecordsThisSessionDidNotLoad() throws {
        let earlier = makeStore(blobs: blobs)
        let image = try ContentFixtures.storedImage(in: blobs)
        let imageID = earlier.record(.image(image), sourceApp: nil, at: start)
        earlier.setPinned(true, id: imageID)
        clock.now = start + 1
        let withoutBlobs = makeStore()
        withoutBlobs.record(text: "other", sourceApp: nil, at: start + 1)

        withoutBlobs.clear(keepingPinned: true)

        // The image record may be pinned; this session never loaded it.
        #expect(Set(disk.records.keys) == [imageID])
        #expect(blobs.allIDs() == Set(image.blobIDs))
    }

    @Test func clearKeepingPinnedDeletesTheDamagedCopyButNotAStoreThatCouldNotBeOpened() {
        let leftovers = FakeHistoryLeftovers(hasDamagedCopy: true, hasUnopenedStore: true)
        let store = makeStore(
            openError: .openFailed, persistence: InMemoryHistoryPersistence(), leftovers: leftovers)
        store.record(text: "other", sourceApp: nil, at: start)

        store.clear(keepingPinned: true)

        #expect(!leftovers.hasDamagedCopy)
        // It may hold pinned entries, and may open at a later launch.
        #expect(leftovers.hasUnopenedStore)
        #expect(store.damagedHistoryBytes == nil)
        #expect(store.entries.isEmpty)
    }
}
