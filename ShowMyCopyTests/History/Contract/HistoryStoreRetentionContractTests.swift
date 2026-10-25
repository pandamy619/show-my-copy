import Foundation
import Testing

@testable import ShowMyCopy

/// The limits (`RetentionPolicy`) as both stores apply them: on every change, when they change, and to a history
/// saved before. Pinned entries are exempt.
@MainActor
struct HistoryStoreRetentionContractTests {
    private let harness = StoreHarness()
    private let start = StoreHarness.start

    private func fill(_ store: any HistoryStore, count: Int) {
        for index in 0..<count {
            store.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
        }
    }

    @Test(arguments: StoreKind.allCases)
    func keepsOnlyTheNewestEntriesWithinTheEntryLimit(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: RetentionPolicy(entryLimit: 10))
        fill(store, count: 12)
        #expect(store.entries.count == 10)
        #expect(store.entries.first?.text == "item 11")
        #expect(store.entries.last?.text == "item 2")
    }

    @Test(arguments: StoreKind.allCases)
    func setRetentionRemovesTheOldestEntriesAndLimitFollowsIt(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: RetentionPolicy(entryLimit: 20))
        fill(store, count: 15)

        store.setRetention(RetentionPolicy(entryLimit: 10))
        #expect(store.limit == 10)
        #expect(store.retention == RetentionPolicy(entryLimit: 10))
        #expect(store.entries.count == 10)
        #expect(store.entries.last?.text == "item 5")

        store.setLimit(100)
        #expect(store.entries.count == 10)
    }

    @Test(arguments: StoreKind.allCases)
    func loweringTheLimitKeepsTheCurrentEntry(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: RetentionPolicy(entryLimit: 20))
        fill(store, count: 15)
        let currentID = store.currentEntryID
        store.setLimit(10)
        #expect(store.currentEntryID == currentID)
    }

    @Test(arguments: StoreKind.allCases)
    func entryLimitIsClampedToTheAllowedRange(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        for (requested, expected) in [(0, 10), (5, 10), (500, 500), (5000, 1000)] {
            store.setLimit(requested)
            #expect(store.limit == expected)
        }
    }

    @Test(arguments: StoreKind.allCases)
    func keepsItsByteLimit(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: RetentionPolicy(byteLimit: 20))
        fill(store, count: 5)
        #expect(store.entries.map(\.text) == ["item 4", "item 3", "item 2"])
        #expect(store.stats().totalBytes == 18)

        store.setLimit(200)
        #expect(store.retention == RetentionPolicy(entryLimit: 200, byteLimit: 20))
    }

    @Test(arguments: StoreKind.allCases)
    func entryLargerThanTheByteLimitIsNotKept(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: RetentionPolicy(byteLimit: 4))
        store.record(text: "too long", sourceApp: nil, at: start)
        #expect(store.entries.isEmpty)
        #expect(store.currentEntryID == nil)
    }

    @Test(arguments: StoreKind.allCases)
    func pinnedEntriesOutliveTheLimitsAndDoNotCountTowardThem(store kind: StoreKind) throws {
        let pinned = StoreHarness.saved("pinned", at: start - 100, pinned: true)
        let store = try harness.make(kind, retention: RetentionPolicy(entryLimit: 10), restoring: [pinned])
        fill(store, count: 12)
        #expect(store.entries.count == 11)
        #expect(store.entries.last?.id == pinned.id)
        #expect(store.entries.dropLast().last?.text == "item 2")

        store.setRetention(RetentionPolicy(entryLimit: 10, byteLimit: 0))
        #expect(store.entries.map(\.id) == [pinned.id])
    }

    @Test(arguments: StoreKind.allCases)
    func clearRemovesPinnedEntriesToo(store kind: StoreKind) throws {
        let pinned = StoreHarness.saved("pinned", at: start, pinned: true)
        let store = try harness.make(kind, restoring: [pinned])
        #expect(store.clear() == ClearResult(removedCount: 1, freedBytes: 6))
        #expect(store.entries.isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func restoringRemovesExpiredPasswordsThenAppliesTheLimit(store kind: StoreKind) throws {
        var saved = (0..<10).map { index in StoreHarness.saved("item \(index)", at: start - Double(index + 1)) }
        saved.insert(StoreHarness.saved("hunter2", at: start, concealed: true, expiresAt: start + 60), at: 0)
        harness.now = start + 60

        let store = try harness.make(kind, retention: RetentionPolicy(entryLimit: 10), restoring: saved)
        #expect(store.entries == Array(saved.dropFirst()))
        #expect(store.currentEntryID == nil)
    }

    @Test(arguments: StoreKind.allCases)
    func restoringAppliesTheLimits(store kind: StoreKind) throws {
        let saved = (0..<15).map { index in StoreHarness.saved("item \(index)", at: start - Double(index)) }
        let store = try harness.make(kind, retention: RetentionPolicy(entryLimit: 10), restoring: saved)
        #expect(store.entries == Array(saved.prefix(10)))
    }
}
