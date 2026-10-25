import Foundation
import Testing

@testable import ShowMyCopy

/// The age limit (`RetentionPolicy.maxAge`) in both stores: entries copied longer ago go, with their blobs, when the
/// monitor looks for expired entries, when the history changes and at launch. Pinned entries stay.
@MainActor
struct HistoryStoreAgeContractTests {
    private let harness = StoreHarness()
    private let start = StoreHarness.start
    private let eightHours = RetentionPolicy(maxAge: .seconds(8 * 3600))

    @Test(arguments: StoreKind.allCases)
    func removeExpiredRemovesEntriesPastTheAgeLimitWithTheirBlobs(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: eightHours)
        let image = try ContentFixtures.storedImage(in: harness.blobs)
        store.record(.image(image), sourceApp: nil, at: start)
        store.record(text: "later", sourceApp: nil, at: start + 3600)

        store.removeExpired(at: start + 8 * 3600 - 1)
        #expect(store.entries.count == 2)

        store.removeExpired(at: start + 8 * 3600)
        #expect(store.entries.map(\.text) == ["later"])
        #expect(try harness.blobs.allIDs().isEmpty)
        #expect(store.currentEntryID == store.entries.first?.id)

        store.removeExpired(at: start + 9 * 3600)
        #expect(store.entries.isEmpty)
        #expect(store.currentEntryID == nil)
    }

    @Test(arguments: StoreKind.allCases)
    func pinnedEntriesStayPastTheAgeLimit(store kind: StoreKind) throws {
        let pinned = StoreHarness.saved("pinned", at: start, pinned: true)
        let store = try harness.make(kind, retention: eightHours, restoring: [pinned])
        store.record(text: "plain", sourceApp: nil, at: start)

        store.removeExpired(at: start + 100 * 3600)
        #expect(store.entries.map(\.id) == [pinned.id])
    }

    @Test(arguments: StoreKind.allCases)
    func removeExpiredChangesNothingWhileNothingIsTooOld(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: eightHours)
        store.record(text: "plain", sourceApp: nil, at: start)
        let revision = store.revision
        store.removeExpired(at: start + 3600)
        #expect(store.revision == revision)
    }

    @Test(arguments: StoreKind.allCases)
    func withoutAnAgeLimitOldEntriesStay(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        store.record(text: "plain", sourceApp: nil, at: start)
        store.removeExpired(at: start + 1000 * 3600)
        #expect(store.entries.map(\.text) == ["plain"])
    }

    @Test(arguments: StoreKind.allCases)
    func settingAnAgeLimitRemovesOlderEntriesByTheStoresClock(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        store.record(text: "old", sourceApp: nil, at: start)
        store.record(text: "recent", sourceApp: nil, at: start + 2 * 3600)
        harness.now = start + 9 * 3600

        store.setRetention(eightHours)
        #expect(store.entries.map(\.text) == ["recent"])
        #expect(store.retention.maxAge == .seconds(8 * 3600))

        store.setRetention(.default)
        harness.now = start + 100 * 3600
        store.record(text: "new", sourceApp: nil, at: harness.now)
        #expect(store.entries.map(\.text) == ["new", "recent"])
    }

    @Test(arguments: StoreKind.allCases)
    func recordingRemovesEntriesThatGrewTooOld(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: eightHours)
        store.record(text: "old", sourceApp: nil, at: start)
        harness.now = start + 8 * 3600
        store.record(text: "new", sourceApp: nil, at: harness.now)
        #expect(store.entries.map(\.text) == ["new"])
    }

    @Test(arguments: StoreKind.allCases)
    func restoringRemovesEntriesPastTheAgeLimit(store kind: StoreKind) throws {
        let saved = [
            StoreHarness.saved("recent", at: start - 3600),
            StoreHarness.saved("old", at: start - 8 * 3600),
            StoreHarness.saved("pinned", at: start - 100 * 3600, pinned: true),
        ]
        let store = try harness.make(kind, retention: eightHours, restoring: saved)
        #expect(store.entries.map(\.text) == ["recent", "pinned"])
    }
}
