import Foundation
import Observation
import Testing

@testable import ShowMyCopy

/// Recording, repeated copies, the current entry, statistics, clearing and change tracking, as `HistoryStore`
/// promises them, for both stores.
@MainActor
struct HistoryStoreContractTests {
    private let harness = StoreHarness()
    private let start = StoreHarness.start
    private let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")
    private let safari = SourceApp(bundleIdentifier: "com.apple.Safari", name: "Safari")

    @Test(arguments: StoreKind.allCases)
    func startsEmptyWithoutCurrentEntry(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        #expect(store.entries.isEmpty)
        #expect(store.currentEntryID == nil)
    }

    @Test(arguments: StoreKind.allCases)
    func newestEntryComesFirstAndBecomesCurrent(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let firstID = store.record(text: "first", sourceApp: notes, at: start)
        #expect(store.currentEntryID == firstID)
        let secondID = store.record(text: "second", sourceApp: notes, at: start + 1)
        #expect(store.entries.map(\.text) == ["second", "first"])
        #expect(store.currentEntryID == secondID)
    }

    @Test(arguments: StoreKind.allCases)
    func recordsContentThroughTheProtocol(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(.text("plain"), sourceApp: nil, at: start)
        let secretID = store.record(.text("secret"), sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)
        #expect(store.entries.map(\.id) == [secretID, id])
        let secret = try #require(store.entries.first)
        #expect(secret.isConcealed)
        #expect(secret.expiresAt == start + 60)
    }

    @Test(arguments: StoreKind.allCases)
    func repeatedCopyMovesToTopWithoutDuplicateAndBecomesCurrent(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let firstID = store.record(text: "first", sourceApp: notes, at: start)
        store.record(text: "second", sourceApp: notes, at: start + 1)
        #expect(store.record(text: "first", sourceApp: safari, at: start + 2) == firstID)

        #expect(store.entries.map(\.text) == ["first", "second"])
        let top = try #require(store.entries.first)
        #expect(top.id == firstID)
        #expect(top.date == start + 2)
        #expect(top.sourceApp == safari)
        #expect(store.currentEntryID == firstID)
    }

    @Test(arguments: StoreKind.allCases)
    func skippedCopyLeavesNoCurrentEntry(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        store.record(text: "first", sourceApp: nil, at: start)
        store.markCurrentSkipped()
        #expect(store.currentEntryID == nil)
        #expect(store.entries.map(\.text) == ["first"])
    }

    @Test(arguments: StoreKind.allCases)
    func markNewestCurrentLeavesTheNewestEntryUnchanged(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        store.record(text: "older", sourceApp: nil, at: start)
        store.record(text: "newest", sourceApp: nil, at: start + 1)
        store.markCurrentSkipped()
        let before = try #require(store.entries.first)

        #expect(store.markNewestCurrent(ifItHolds: .text("newest")) == before.id)
        #expect(store.currentEntryID == before.id)
        #expect(store.entries.first == before)
    }

    @Test(arguments: StoreKind.allCases)
    func markNewestCurrentIgnoresOtherContent(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        #expect(store.markNewestCurrent(ifItHolds: .text("anything")) == nil)
        store.record(text: "older", sourceApp: nil, at: start)
        store.record(text: "newest", sourceApp: nil, at: start + 1)
        store.markCurrentSkipped()

        #expect(store.markNewestCurrent(ifItHolds: .text("older")) == nil)
        #expect(store.currentEntryID == nil)
        #expect(store.entries.map(\.text) == ["newest", "older"])
    }

    @Test(arguments: StoreKind.allCases)
    func statsCountEntriesAndBytes(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        #expect(store.stats() == HistoryStats(count: 0, totalBytes: 0))
        store.record(text: "abc", sourceApp: nil, at: start)
        store.record(text: "\u{E9}", sourceApp: nil, at: start + 1)
        #expect(store.stats() == HistoryStats(count: 2, totalBytes: 5))
    }

    @Test(arguments: StoreKind.allCases)
    func clearRemovesEveryEntryAndReportsWhatItRemoved(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        store.record(text: "abc", sourceApp: nil, at: start)
        store.record(text: "de", sourceApp: nil, at: start + 1)
        #expect(store.clear() == ClearResult(removedCount: 2, freedBytes: 5))
        #expect(store.entries.isEmpty)
        #expect(store.currentEntryID == nil)
        #expect(store.clear() == ClearResult(removedCount: 0, freedBytes: 0))
    }

    @Test(arguments: StoreKind.allCases)
    func removeDeletesOneEntry(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let firstID = store.record(text: "first", sourceApp: nil, at: start)
        let secondID = store.record(text: "second", sourceApp: nil, at: start + 1)

        store.remove(id: firstID)
        #expect(store.entries.map(\.text) == ["second"])
        #expect(store.currentEntryID == secondID)

        store.remove(id: secondID)
        #expect(store.entries.isEmpty)
        #expect(store.currentEntryID == nil)
    }

    @Test(arguments: StoreKind.allCases)
    func observersSeeNewEntriesAndASkippedCopy(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let entriesChanged = ChangeFlag()
        withObservationTracking {
            _ = store.entries
        } onChange: {
            entriesChanged.set()
        }
        store.record(text: "new", sourceApp: nil, at: start)
        #expect(entriesChanged.value)

        let currentChanged = ChangeFlag()
        withObservationTracking {
            _ = store.currentEntryID
        } onChange: {
            currentChanged.set()
        }
        store.markCurrentSkipped()
        #expect(currentChanged.value)
    }

    @Test(arguments: StoreKind.allCases)
    func observersOfTheRevisionSeeChanges(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let changed = ChangeFlag()
        withObservationTracking {
            _ = store.revision
        } onChange: {
            changed.set()
        }
        store.record(text: "new", sourceApp: nil, at: start)
        #expect(changed.value)
    }

    @Test(arguments: StoreKind.allCases)
    func revisionChangesWithEveryChangeToTheEntries(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        var revisions = [store.revision]
        func expectNewRevision(_ comment: Comment) {
            #expect(!revisions.contains(store.revision), comment)
            revisions.append(store.revision)
        }
        let first = store.record(text: "first", sourceApp: nil, at: start)
        expectNewRevision("record")
        store.record(text: "second", sourceApp: nil, at: start + 1)
        store.record(text: "first", sourceApp: nil, at: start + 2)
        expectNewRevision("record moves an entry to the top")
        store.conceal(id: first, expiresAt: start + 60)
        expectNewRevision("conceal")
        store.limitExpiry(to: start + 30)
        expectNewRevision("limitExpiry")
        store.removeExpired(at: start + 30)
        expectNewRevision("removeExpired")
        let second = try #require(store.entries.first?.id)
        store.remove(id: second)
        expectNewRevision("remove")
        for index in 0..<11 {
            store.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
        }
        revisions.append(store.revision)
        store.setRetention(RetentionPolicy(entryLimit: 10))
        expectNewRevision("setRetention removes an entry")
        store.record(text: "secret", sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)
        revisions.append(store.revision)
        store.removeConcealed()
        expectNewRevision("removeConcealed")
        store.clear()
        expectNewRevision("clear")
    }

    @Test(arguments: StoreKind.allCases)
    func revisionStaysWhenTheEntriesStay(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        store.record(text: "plain", sourceApp: nil, at: start)
        let revision = store.revision
        store.removeExpired(at: start + 1000)
        store.removeConcealed()
        store.limitExpiry(to: start)
        store.remove(id: UUID())
        store.conceal(id: UUID(), expiresAt: start)
        store.markCurrentSkipped()
        store.markNewestCurrent(ifItHolds: .text("plain"))
        store.setRetention(RetentionPolicy(entryLimit: 20))
        #expect(store.revision == revision)

        let empty = try StoreHarness().make(kind)
        let emptyRevision = empty.revision
        empty.clear()
        #expect(empty.revision == emptyRevision)
    }
}
