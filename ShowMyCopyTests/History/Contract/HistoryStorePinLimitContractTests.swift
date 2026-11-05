import Foundation
import Testing

@testable import ShowMyCopy

/// At most `RetentionPolicy.maximumPinned` entries are pinned, in both stores. Pinning one more unpins the oldest
/// pinned entry, as if the user unpinned it then: it goes to the top of the history and the limits count it again.
/// Undo and loading a saved history keep the limit the same way.
@MainActor
struct HistoryStorePinLimitContractTests {
    private let harness = StoreHarness()
    private let start = StoreHarness.start
    private let limit = RetentionPolicy.maximumPinned

    /// Records and pins "pin 0" to "pin <count - 1>" in that order, one second apart, then records "copy". The clock
    /// is left at the last pin, before `start + 1100`: later copies are made after that, as a copy is always newest.
    @discardableResult
    private func pinMany(_ count: Int, in store: any HistoryStore) -> [ClipboardEntry.ID] {
        let ids = (0..<count).map { index in
            harness.now = start + 1000 + Double(index)
            let id = store.record(text: "pin \(index)", sourceApp: nil, at: harness.now)
            store.setPinned(true, id: id)
            return id
        }
        store.record(text: "copy", sourceApp: nil, at: start + 1000 + Double(count))
        return ids
    }

    /// The pinned texts in the order they were pinned, oldest first, as the history window lists them.
    private func pinnedTexts(in store: any HistoryStore) -> [String] {
        store.entries.filter(\.isPinned).reversed().compactMap(\.text)
    }

    /// The pinned entries and the others, each newest first. An entry unpinned to keep the limit and the one pinned
    /// with it have the same date, so the order of the two in `entries` is not part of the contract.
    private func sections(of store: any HistoryStore) -> [[ClipboardEntry]] {
        [store.entries.filter(\.isPinned), store.entries.filter { !$0.isPinned }]
    }

    private func texts(_ range: Range<Int>) -> [String] {
        range.map { "pin \($0)" }
    }

    /// A store of `kind` started again from what `store` kept: for the persistent store, from its disk.
    private func relaunch(_ kind: StoreKind, _ store: any HistoryStore) throws -> any HistoryStore {
        try harness.make(kind, restoring: kind == .inMemory ? store.entries : [])
    }

    @Test func theLimitIsFifty() {
        #expect(RetentionPolicy.maximumPinned == 50)
    }

    @Test(arguments: StoreKind.allCases)
    func fiftyEntriesCanBePinned(store kind: StoreKind) throws {
        let store = try harness.make(kind)

        pinMany(limit, in: store)

        #expect(pinnedTexts(in: store) == texts(0..<limit))
        #expect(store.entries.count == limit + 1)
    }

    @Test(arguments: StoreKind.allCases)
    func pinningTheFiftyFirstUnpinsTheOldestPinnedAndPutsItOnTop(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let pins = pinMany(limit, in: store)
        let new = store.record(text: "new", sourceApp: nil, at: start + 1100)

        harness.now = start + 2000
        store.setPinned(true, id: new)

        #expect(pinnedTexts(in: store) == texts(1..<limit) + ["new"])
        // Unpinned as the user unpins an entry: at the top of the history, dated now, so the age limit keeps it.
        let unpinned = try #require(store.entries.first { !$0.isPinned })
        #expect(unpinned.id == pins[0])
        #expect(unpinned.date == start + 2000)
        #expect(store.entries.filter { !$0.isPinned }.map(\.text) == ["pin 0", "copy"])
    }

    @Test(arguments: StoreKind.allCases)
    func eachPinPastTheLimitUnpinsTheNextOldest(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        pinMany(limit, in: store)
        let first = store.record(text: "new 1", sourceApp: nil, at: start + 1100)
        let second = store.record(text: "new 2", sourceApp: nil, at: start + 1101)

        harness.now = start + 2000
        store.setPinned(true, id: first)
        harness.now = start + 2001
        store.setPinned(true, id: second)

        #expect(pinnedTexts(in: store) == texts(2..<limit) + ["new 1", "new 2"])
        #expect(store.entries.filter { !$0.isPinned }.map(\.text) == ["pin 1", "pin 0", "copy"])
        #expect(store.entries.filter(\.isPinned).count == limit)
    }

    @Test(arguments: StoreKind.allCases)
    func theUnpinnedEntryCountsTowardTheLimitsAgain(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: RetentionPolicy(entryLimit: 10))
        pinMany(limit, in: store)
        for index in 0..<9 {
            store.record(text: "item \(index)", sourceApp: nil, at: start + 1100 + Double(index))
        }
        let new = store.record(text: "new", sourceApp: nil, at: start + 1200)
        #expect(store.entries.filter { !$0.isPinned }.count == 10)

        harness.now = start + 2000
        store.setPinned(true, id: new)

        // "pin 0" is back and counts: the oldest unpinned entry, "copy", goes.
        let history = store.entries.filter { !$0.isPinned }.map(\.text)
        #expect(history.count == 10)
        #expect(history.first == "pin 0")
        #expect(!history.contains("copy"))
    }

    @Test(arguments: StoreKind.allCases)
    func theUnpinnedEntryOutlivesAnAgeLimitItsPinIsOlderThan(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: RetentionPolicy(maxAge: .seconds(3600)))
        let pins = pinMany(limit, in: store)
        harness.now = start + 10 * 3600
        let new = store.record(text: "new", sourceApp: nil, at: harness.now)

        store.setPinned(true, id: new)
        store.removeExpired(at: harness.now)

        #expect(store.entries.first { !$0.isPinned }?.id == pins[0])
    }

    @Test(arguments: StoreKind.allCases)
    func theReplacementSurvivesARelaunch(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        pinMany(limit, in: store)
        let new = store.record(text: "new", sourceApp: nil, at: start + 1100)
        harness.now = start + 2000
        store.setPinned(true, id: new)

        let relaunched = try relaunch(kind, store)

        #expect(sections(of: relaunched) == sections(of: store))
        #expect(pinnedTexts(in: relaunched) == texts(1..<limit) + ["new"])
        #expect(relaunched.entries.filter { !$0.isPinned }.map(\.text) == ["pin 0", "copy"])
    }

    @Test(arguments: StoreKind.allCases)
    func undoingTheDeleteOfAPinnedEntryWithFiftyPinnedUnpinsTheOldest(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let pins = pinMany(limit, in: store)
        let deleted = try #require(store.entries.first { $0.id == pins[10] })
        store.remove(id: pins[10])
        let new = store.record(text: "new", sourceApp: nil, at: start + 1100)
        harness.now = start + 2000
        store.setPinned(true, id: new)
        #expect(store.entries.allSatisfy { $0.isPinned || $0.text == "copy" })

        harness.now = start + 2010
        store.restore([deleted])

        // Back at its place among the pinned; the oldest pinned entry makes room.
        #expect(pinnedTexts(in: store) == texts(1..<limit) + ["new"])
        let unpinned = try #require(store.entries.first { !$0.isPinned })
        #expect(unpinned.text == "pin 0")
        #expect(!unpinned.isPinned)
        #expect(unpinned.date == start + 2010)
        #expect(sections(of: try relaunch(kind, store)) == sections(of: store))
    }

    @Test(arguments: StoreKind.allCases)
    func undoingTheDeleteOfTheOldestPinnedEntryWithFiftyPinnedBringsItBackUnpinned(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let pins = pinMany(limit, in: store)
        let deleted = try #require(store.entries.first { $0.id == pins[0] })
        store.remove(id: pins[0])
        let new = store.record(text: "new", sourceApp: nil, at: start + 1100)
        harness.now = start + 2000
        store.setPinned(true, id: new)

        harness.now = start + 2010
        store.restore([deleted])

        // The newest fifty stay pinned: the entry brought back is the oldest, so it goes on top of the history.
        #expect(pinnedTexts(in: store) == texts(1..<limit) + ["new"])
        let restored = try #require(store.entries.first { !$0.isPinned })
        #expect(restored.id == pins[0])
        #expect(!restored.isPinned)
        #expect(restored.date == start + 2010)
    }

    @Test(arguments: StoreKind.allCases)
    func aSavedHistoryWithMoreThanFiftyPinnedKeepsTheNewestFiftyPinned(store kind: StoreKind) throws {
        // Pinned before there was a limit: 53, newest first, and two copies.
        let pinned = (0..<limit + 3).reversed().map { index in
            StoreHarness.saved("pin \(index)", at: start - 1000 + Double(index), pinned: true)
        }
        let copies = [StoreHarness.saved("copy 1", at: start - 10), StoreHarness.saved("copy 0", at: start - 20)]
        let saved = (pinned + copies).sorted { $0.date > $1.date }

        let store = try harness.make(kind, restoring: saved)

        #expect(pinnedTexts(in: store) == texts(3..<limit + 3))
        // Unpinned at launch, newest pin first, above the copies, as if the user unpinned them then.
        let history = store.entries.filter { !$0.isPinned }
        #expect(history.map(\.text) == ["pin 2", "pin 1", "pin 0", "copy 1", "copy 0"])
        #expect(history.prefix(3).allSatisfy { $0.date <= start && $0.date > start - 1 })
        #expect(try relaunch(kind, store).entries == store.entries)
    }

    @Test(arguments: StoreKind.allCases)
    func aSavedHistoryWithFiftyPinnedLoadsAsItIs(store kind: StoreKind) throws {
        let saved = (0..<limit).reversed().map { index in
            StoreHarness.saved("pin \(index)", at: start - 1000 + Double(index), pinned: true)
        }

        let store = try harness.make(kind, restoring: saved)

        #expect(store.entries == saved)
    }
}
