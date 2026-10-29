import Foundation
import Testing

@testable import ShowMyCopy

/// Pinning (`setPinned`) as both stores do it: pinned entries keep the order they were pinned in, outlive the limits
/// and Clear History when the user keeps them, and are never passwords.
@MainActor
struct HistoryStorePinContractTests {
    private let harness = StoreHarness()
    private let start = StoreHarness.start
    private let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")

    private func fill(_ store: any HistoryStore, count: Int, from date: Date) {
        for index in 0..<count {
            store.record(text: "item \(index)", sourceApp: nil, at: date + Double(index))
        }
    }

    private func entry(_ id: ClipboardEntry.ID, in store: any HistoryStore) throws -> ClipboardEntry {
        try #require(store.entries.first { $0.id == id })
    }

    @Test(arguments: StoreKind.allCases)
    func pinnedEntriesKeepTheOrderTheyWerePinnedIn(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let first = store.record(text: "first", sourceApp: nil, at: start)
        store.record(text: "second", sourceApp: nil, at: start + 1)
        let third = store.record(text: "third", sourceApp: nil, at: start + 2)

        harness.now = start + 10
        store.setPinned(true, id: first)
        harness.now = start + 20
        store.setPinned(true, id: third)

        // Newest first by date, and a pinned entry's date is when it was pinned.
        #expect(store.entries.map(\.text) == ["third", "first", "second"])
        #expect(store.entries.filter(\.isPinned).map(\.date) == [start + 20, start + 10])
        #expect(try entry(first, in: store).isPinned)
    }

    @Test(arguments: StoreKind.allCases)
    func pinnedEntriesOutliveTheEntrySizeAndAgeLimits(store kind: StoreKind) throws {
        let policy = RetentionPolicy(entryLimit: 10, byteLimit: 1000, maxAge: .seconds(3600))
        let store = try harness.make(kind, retention: policy)
        let id = store.record(text: "pinned", sourceApp: nil, at: start)
        store.setPinned(true, id: id)

        fill(store, count: 12, from: start + 1)
        #expect(store.entries.count == 11)
        #expect(store.entries.contains { $0.id == id })

        store.setRetention(policy.withByteLimit(0))
        #expect(store.entries.map(\.id) == [id])

        store.removeExpired(at: start + 100 * 3600)
        #expect(store.entries.map(\.id) == [id])
    }

    @Test(arguments: StoreKind.allCases)
    func copyingPinnedContentAgainMakesItCurrentWithoutMovingIt(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "pinned", sourceApp: nil, at: start)
        harness.now = start + 1
        store.setPinned(true, id: id)
        let other = store.record(text: "other", sourceApp: nil, at: start + 2)
        let revision = store.revision

        #expect(store.record(text: "pinned", sourceApp: notes, at: start + 3) == id)

        #expect(store.currentEntryID == id)
        #expect(store.entries.map(\.id) == [other, id])
        let pinned = try entry(id, in: store)
        #expect(pinned.isPinned)
        #expect(pinned.date == start + 1)
        #expect(pinned.sourceApp == nil)
        #expect(store.revision == revision)
    }

    @Test(arguments: StoreKind.allCases)
    func aPasswordIsNeverPinned(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)
        let revision = store.revision

        store.setPinned(true, id: id)

        #expect(try !entry(id, in: store).isPinned)
        #expect(store.revision == revision)
    }

    @Test(arguments: StoreKind.allCases)
    func concealingAPinnedEntryUnpinsIt(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "hunter2", sourceApp: nil, at: start)
        store.setPinned(true, id: id)

        store.conceal(id: id, expiresAt: start + 60)

        let concealed = try entry(id, in: store)
        #expect(concealed.isConcealed)
        #expect(!concealed.isPinned)
        #expect(concealed.expiresAt == start + 60)
    }

    @Test(arguments: StoreKind.allCases)
    func aConcealedCopyOfPinnedContentUnpinsItAndMovesItToTheTop(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "hunter2", sourceApp: nil, at: start)
        store.setPinned(true, id: id)
        store.record(text: "other", sourceApp: nil, at: start + 1)

        store.record(text: "hunter2", sourceApp: notes, at: start + 2, concealed: true, expiresAt: start + 60)

        let concealed = try #require(store.entries.first)
        #expect(concealed.id == id)
        #expect(concealed.isConcealed)
        #expect(!concealed.isPinned)
        #expect(concealed.date == start + 2)
    }

    @Test(arguments: StoreKind.allCases)
    func unpinningPutsTheEntryOnTopAndTheLimitsCountItAgain(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: RetentionPolicy(entryLimit: 10))
        let id = store.record(text: "pinned", sourceApp: nil, at: start)
        store.setPinned(true, id: id)
        fill(store, count: 10, from: start + 1)

        harness.now = start + 20
        store.setPinned(false, id: id)

        let unpinned = try #require(store.entries.first)
        #expect(unpinned.id == id)
        #expect(!unpinned.isPinned)
        #expect(unpinned.date == start + 20)
        // Eleven entries count toward a limit of ten: the oldest goes.
        #expect(store.entries.count == 10)
        #expect(!store.entries.contains { $0.text == "item 0" })
    }

    @Test(arguments: StoreKind.allCases)
    func unpinningAnEntryPinnedLongerAgoThanTheAgeLimitKeepsIt(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: RetentionPolicy(maxAge: .seconds(3600)))
        let id = store.record(text: "pinned", sourceApp: nil, at: start)
        store.setPinned(true, id: id)

        harness.now = start + 5 * 3600
        store.removeExpired(at: harness.now)
        store.setPinned(false, id: id)
        store.removeExpired(at: harness.now)

        #expect(store.entries.map(\.id) == [id])
        #expect(store.entries.first?.date == start + 5 * 3600)
    }

    @Test(arguments: StoreKind.allCases)
    func pinningAnEntryInThatStateOrOneThatIsGoneChangesNothing(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "text", sourceApp: nil, at: start)
        let revision = store.revision

        store.setPinned(false, id: id)
        store.setPinned(true, id: UUID())

        #expect(store.revision == revision)
        #expect(store.entries.map(\.date) == [start])
    }

    @Test(arguments: StoreKind.allCases)
    func aPinnedEntryCanBeDeleted(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "pinned", sourceApp: nil, at: start)
        store.setPinned(true, id: id)

        store.remove(id: id)

        #expect(store.entries.isEmpty)
        #expect(store.currentEntryID == nil)
    }

    @Test(arguments: StoreKind.allCases)
    func clearKeepingPinnedRemovesOnlyTheOtherEntries(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "pinned", sourceApp: nil, at: start)
        store.setPinned(true, id: id)
        store.record(text: "one", sourceApp: nil, at: start + 1)
        store.record(text: "two", sourceApp: nil, at: start + 2)

        #expect(store.clear(keepingPinned: true) == ClearResult(removedCount: 2, freedBytes: 6))

        #expect(store.entries.map(\.id) == [id])
        // "two" was current and is gone.
        #expect(store.currentEntryID == nil)
        #expect(store.clear(keepingPinned: true) == ClearResult(removedCount: 0, freedBytes: 0))
    }

    @Test(arguments: StoreKind.allCases)
    func aPinnedEntryOnTheClipboardStaysCurrentWhenClearKeepsIt(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "pinned", sourceApp: nil, at: start)
        store.setPinned(true, id: id)
        store.record(text: "other", sourceApp: nil, at: start + 1)
        store.record(text: "pinned", sourceApp: nil, at: start + 2)

        store.clear(keepingPinned: true)

        #expect(store.currentEntryID == id)
    }

    @Test(arguments: StoreKind.allCases)
    func clearKeepingPinnedDeletesTheBlobsOfTheOthersOnly(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let pinnedImage = try ContentFixtures.storedImage(in: harness.blobs, bytes: Data(repeating: 1, count: 100))
        let id = store.record(.image(pinnedImage), sourceApp: nil, at: start)
        store.setPinned(true, id: id)
        let other = try ContentFixtures.storedImage(in: harness.blobs, bytes: Data(repeating: 2, count: 100))
        store.record(.image(other), sourceApp: nil, at: start + 1)

        store.clear(keepingPinned: true)

        #expect(try harness.blobs.allIDs() == Set(pinnedImage.blobIDs))
        expectEveryBlobBelongsToAnEntry(of: store, in: harness.blobs)
    }

    @Test(arguments: StoreKind.allCases)
    func clearWithoutKeepingPinnedRemovesThemToo(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "pinned", sourceApp: nil, at: start)
        store.setPinned(true, id: id)
        store.record(text: "other", sourceApp: nil, at: start + 1)

        #expect(store.clear(keepingPinned: false) == ClearResult(removedCount: 2, freedBytes: 11))
        #expect(store.entries.isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func theClipboardAtLaunchFindsTheNewestEntryBehindNewerPins(store kind: StoreKind) throws {
        let saved = [
            StoreHarness.saved("pinned", at: start, pinned: true),
            StoreHarness.saved("newest copy", at: start - 10),
            StoreHarness.saved("older pin", at: start - 20, pinned: true),
            StoreHarness.saved("older copy", at: start - 30),
        ]
        let store = try harness.make(kind, restoring: saved)

        #expect(store.markNewestCurrent(ifItHolds: .text("newest copy")) == saved[1].id)
        #expect(store.markNewestCurrent(ifItHolds: .text("pinned")) == saved[0].id)
        #expect(store.markNewestCurrent(ifItHolds: .text("older copy")) == nil)
        // An older pin is not the newest entry; recording it again changes nothing about it either.
        #expect(store.markNewestCurrent(ifItHolds: .text("older pin")) == nil)
    }

    @Test(arguments: StoreKind.allCases)
    func undoingTheDeleteOfAPinnedEntryPutsItBackAmongThePinned(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "pinned", sourceApp: nil, at: start)
        harness.now = start + 5
        store.setPinned(true, id: id)
        store.record(text: "newer", sourceApp: nil, at: start + 6)
        let deleted = try entry(id, in: store)
        store.remove(id: id)

        store.restore([deleted])

        #expect(store.entries.map(\.text) == ["newer", "pinned"])
        #expect(try entry(id, in: store).isPinned)
    }
}
