import Foundation
import Observation
import Testing

@testable import ShowMyCopy

/// Set from an observation callback, which may run on any thread.
private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var value: Bool {
        lock.withLock { isSet }
    }

    func set() {
        lock.withLock { isSet = true }
    }
}

@MainActor
struct HistoryStoreTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// The app talks to the store through the protocol, so these tests do too.
    private func makeStore() -> any HistoryStore {
        InMemoryHistoryStore()
    }

    @Test func statsCountEntriesAndBytes() {
        let store = makeStore()
        #expect(store.stats() == HistoryStats(count: 0, totalBytes: 0))
        store.record(text: "abc", sourceApp: nil, at: start)
        store.record(text: "\u{E9}", sourceApp: nil, at: start + 1)
        #expect(store.stats() == HistoryStats(count: 2, totalBytes: 5))
    }

    @Test func clearReportsWhatItRemoved() {
        let store = makeStore()
        store.record(text: "abc", sourceApp: nil, at: start)
        store.record(text: "de", sourceApp: nil, at: start + 1)
        #expect(store.clear() == ClearResult(removedCount: 2, freedBytes: 5))
        #expect(store.entries.isEmpty)
        #expect(store.clear() == ClearResult(removedCount: 0, freedBytes: 0))
    }

    @Test func recordsContentThroughTheProtocol() throws {
        let store = makeStore()
        let id = store.record(.text("plain"), sourceApp: nil, at: start)
        let secretID = store.record(.text("secret"), sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)
        #expect(store.entries.map(\.id) == [secretID, id])
        let secret = try #require(store.entries.first)
        #expect(secret.isConcealed)
        #expect(secret.expiresAt == start + 60)
    }

    @Test func setRetentionTrimsAndLimitFollowsIt() {
        let store = makeStore()
        for index in 0..<15 {
            store.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
        }
        store.setRetention(RetentionPolicy(entryLimit: 10))
        #expect(store.limit == 10)
        #expect(store.retention == RetentionPolicy(entryLimit: 10))
        #expect(store.entries.count == 10)
    }

    @Test func observersOfTheProtocolSeeChanges() {
        let store = makeStore()
        let changed = ChangeFlag()
        withObservationTracking {
            _ = store.entries
        } onChange: {
            changed.set()
        }
        #expect(!changed.value)
        store.record(text: "new", sourceApp: nil, at: start)
        #expect(changed.value)
    }

    @Test func observersOfTheCurrentEntrySeeASkippedCopy() {
        let store = makeStore()
        store.record(text: "new", sourceApp: nil, at: start)
        let changed = ChangeFlag()
        withObservationTracking {
            _ = store.currentEntryID
        } onChange: {
            changed.set()
        }
        store.markCurrentSkipped()
        #expect(changed.value)
    }
}
