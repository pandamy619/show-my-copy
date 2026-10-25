import Foundation
import Testing

@testable import ShowMyCopy

/// Concealed entries (passwords) and their expiry, for both stores.
@MainActor
struct HistoryStoreConcealedContractTests {
    private let harness = StoreHarness()
    private let start = StoreHarness.start
    private let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")

    @Test(arguments: StoreKind.allCases)
    func plainEntryIsNotConcealed(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        store.record(text: "plain", sourceApp: nil, at: start)
        let entry = try #require(store.entries.first)
        #expect(!entry.isConcealed)
        #expect(entry.expiresAt == nil)
    }

    @Test(arguments: StoreKind.allCases)
    func secretCopyOfPlainTextConcealsTheEntry(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "hunter2", sourceApp: notes, at: start)
        store.record(text: "other", sourceApp: nil, at: start + 1)

        store.record(text: "hunter2", sourceApp: nil, at: start + 2, concealed: true, expiresAt: start + 62)
        #expect(store.entries.count == 2)
        let entry = try #require(store.entries.first)
        #expect(entry.id == id)
        #expect(entry.isConcealed)
        #expect(entry.expiresAt == start + 62)
    }

    @Test(arguments: StoreKind.allCases)
    func plainCopyOfConcealedTextStaysConcealed(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        store.record(text: "other", sourceApp: nil, at: start + 1)

        // Pasted into a note and copied from there: still a password.
        store.record(text: "hunter2", sourceApp: notes, at: start + 2)
        #expect(store.entries.count == 2)
        let entry = try #require(store.entries.first)
        #expect(entry.id == id)
        #expect(entry.isConcealed)
        #expect(entry.expiresAt == start + 600)
    }

    @Test(arguments: StoreKind.allCases)
    func removeExpiredRemovesOnlyConcealedEntriesPastTheirExpiry(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        store.record(text: "soon", sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)
        store.record(text: "later", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        store.record(text: "plain", sourceApp: nil, at: start)

        store.removeExpired(at: start + 59)
        #expect(store.entries.map(\.text) == ["plain", "later", "soon"])

        store.removeExpired(at: start + 60)
        #expect(store.entries.map(\.text) == ["plain", "later"])

        store.removeExpired(at: start + 100_000)
        #expect(store.entries.map(\.text) == ["plain"])
    }

    @Test(arguments: StoreKind.allCases)
    func removingTheCurrentEntryLeavesNoCurrentEntry(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        store.record(text: "plain", sourceApp: nil, at: start)
        store.record(text: "secret", sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)

        store.removeExpired(at: start + 60)
        #expect(store.currentEntryID == nil)
    }

    @Test(arguments: StoreKind.allCases)
    func removeConcealedRemovesEveryConcealedEntry(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        store.record(text: "first secret", sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)
        store.record(text: "plain", sourceApp: nil, at: start)
        store.record(text: "second secret", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)

        store.removeConcealed()
        #expect(store.entries.map(\.text) == ["plain"])
        #expect(store.currentEntryID == nil)
    }

    @Test(arguments: StoreKind.allCases)
    func concealHidesAPlainEntry(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "hunter2", sourceApp: nil, at: start)

        store.conceal(id: id, expiresAt: start + 600)
        let entry = try #require(store.entries.first)
        #expect(entry.isConcealed)
        #expect(entry.expiresAt == start + 600)
        #expect(store.currentEntryID == id)
    }

    @Test(arguments: StoreKind.allCases)
    func concealNeverMakesAnExpiryLater(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(text: "secret", sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)

        store.conceal(id: id, expiresAt: start + 600)
        #expect(store.entries.first?.expiresAt == start + 60)

        store.conceal(id: id, expiresAt: start + 30)
        #expect(store.entries.first?.expiresAt == start + 30)
    }

    @Test(arguments: StoreKind.allCases)
    func concealedRichTextIsKeptConcealed(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(ContentFixtures.richText("pw"), sourceApp: nil, at: start)
        store.conceal(id: id, expiresAt: start + 60)
        #expect(store.entries.first?.isConcealed == true)
    }

    @Test(arguments: StoreKind.allCases)
    func shorterLifetimeMovesLaterExpiriesEarlier(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        store.record(text: "soon", sourceApp: nil, at: start, concealed: true, expiresAt: start + 30)
        store.record(text: "later", sourceApp: nil, at: start, concealed: true, expiresAt: start + 3600)
        store.record(text: "plain", sourceApp: nil, at: start)

        store.limitExpiry(to: start + 60)
        #expect(store.entries.map(\.expiresAt) == [nil, start + 60, start + 30])
    }
}
