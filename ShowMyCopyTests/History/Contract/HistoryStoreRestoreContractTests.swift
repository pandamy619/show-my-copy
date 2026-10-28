import Foundation
import Testing

@testable import ShowMyCopy

/// Putting back an entry removed earlier in the session, as Undo after deleting one in the history window does, in
/// both stores.
@MainActor
struct HistoryStoreRestoreContractTests {
    private let base = InMemoryBlobStore()
    private let blobs: InFlightBlobStore
    private let harness: StoreHarness
    private let start = StoreHarness.start

    init() {
        blobs = InFlightBlobStore(base: base)
        harness = StoreHarness(blobs: blobs)
    }

    private func entry(_ id: ClipboardEntry.ID, in store: any HistoryStore) throws -> ClipboardEntry {
        try #require(store.entries.first { $0.id == id })
    }

    @Test(arguments: StoreKind.allCases)
    func restorePutsTheEntryBackAtItsPlaceWithItsID(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        store.record(text: "first", sourceApp: nil, at: start)
        let secondID = store.record(text: "second", sourceApp: nil, at: start + 1)
        let thirdID = store.record(text: "third", sourceApp: nil, at: start + 2)
        let second = try entry(secondID, in: store)

        store.remove(id: secondID)
        store.restore([second])

        #expect(store.entries.map(\.text) == ["third", "second", "first"])
        #expect(try entry(secondID, in: store) == second)
        #expect(store.currentEntryID == thirdID)
    }

    @Test(arguments: StoreKind.allCases)
    func restoredEntryDoesNotBecomeCurrent(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "only", sourceApp: nil, at: start)
        let only = try entry(id, in: store)

        store.remove(id: id)
        let revision = store.revision
        store.restore([only])

        #expect(store.entries.map(\.id) == [id])
        #expect(store.currentEntryID == nil)
        #expect(store.revision != revision)
    }

    @Test(arguments: StoreKind.allCases)
    func contentCopiedAgainMeanwhileIsNotAddedTwice(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "again", sourceApp: nil, at: start)
        let removed = try entry(id, in: store)
        store.remove(id: id)
        let copiedAgain = store.record(text: "again", sourceApp: nil, at: start + 5)

        store.restore([removed])

        #expect(store.entries.map(\.id) == [copiedAgain])
        #expect(store.currentEntryID == copiedAgain)
    }

    @Test(arguments: StoreKind.allCases)
    func restoredPasswordStaysConcealedWithItsExpiry(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        let password = try entry(id, in: store)

        store.remove(id: id)
        store.restore([password])

        let restored = try entry(id, in: store)
        #expect(restored.isConcealed)
        #expect(restored.expiresAt == start + 600)
    }

    @Test(arguments: StoreKind.allCases)
    func limitsApplyToTheRestoredEntry(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: RetentionPolicy(entryLimit: 10))
        let oldestID = store.record(text: "oldest", sourceApp: nil, at: start)
        let oldest = try entry(oldestID, in: store)
        store.remove(id: oldestID)
        for index in 1...10 {
            store.record(text: "text \(index)", sourceApp: nil, at: start + Double(index))
        }

        store.restore([oldest])

        #expect(store.entries.count == 10)
        #expect(!store.entries.contains { $0.id == oldestID })
    }

    /// The caller keeps the blobs of a removed entry by holding them, so removing it only puts their deletion off.
    /// Restored, the entry owns them again: they are used, and they go when it is removed for good.
    @Test(arguments: StoreKind.allCases)
    func restoredImageOwnsItsBlobsAgain(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let image = try ContentFixtures.storedImage(in: blobs, bytes: Data(repeating: 7, count: 100))
        let id = store.record(.image(image), sourceApp: nil, at: start)
        let removed = try entry(id, in: store)
        let reservation = blobs.reservation()
        reservation.hold(image.blobIDs)

        store.remove(id: id)
        store.restore([removed])
        let released = reservation.release()

        #expect(Set(released) == Set(image.blobIDs))
        #expect(Set(store.entries.flatMap(\.content.blobIDs)) == Set(image.blobIDs))
        #expect(base.allIDs() == Set(image.blobIDs))

        store.remove(id: id)
        #expect(base.allIDs().isEmpty)
    }
}
