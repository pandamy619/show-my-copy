import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct ClipboardHistoryTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")
    private let safari = SourceApp(bundleIdentifier: "com.apple.Safari", name: "Safari")

    @Test func startsEmpty() {
        #expect(ClipboardHistory().entries.isEmpty)
    }

    @Test func newestEntryComesFirst() {
        let history = ClipboardHistory()
        history.record(text: "first", sourceApp: notes, at: start)
        history.record(text: "second", sourceApp: notes, at: start + 1)
        #expect(history.entries.map(\.text) == ["second", "first"])
    }

    @Test func repeatedCopyMovesToTopWithoutDuplicate() throws {
        let history = ClipboardHistory()
        history.record(text: "first", sourceApp: notes, at: start)
        let firstID = try #require(history.entries.first?.id)
        history.record(text: "second", sourceApp: notes, at: start + 1)
        history.record(text: "first", sourceApp: safari, at: start + 2)

        #expect(history.entries.map(\.text) == ["first", "second"])
        let top = try #require(history.entries.first)
        #expect(top.id == firstID)
        #expect(top.date == start + 2)
        #expect(top.sourceApp == safari)
    }

    @Test func keepsOnlyNewestEntriesWithinLimit() {
        let history = ClipboardHistory(limit: 10)
        for index in 0..<12 {
            history.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
        }
        #expect(history.entries.count == 10)
        #expect(history.entries.first?.text == "item 11")
        #expect(history.entries.last?.text == "item 2")
    }

    @Test func loweringLimitRemovesOldestEntries() {
        let history = ClipboardHistory(limit: 20)
        for index in 0..<15 {
            history.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
        }
        #expect(history.entriesRemoved(byLimit: 10) == 5)

        history.setLimit(10)
        #expect(history.limit == 10)
        #expect(history.entries.count == 10)
        #expect(history.entries.last?.text == "item 5")
    }

    @Test func raisingLimitRemovesNothing() {
        let history = ClipboardHistory(limit: 10)
        history.record(text: "item", sourceApp: nil, at: start)
        #expect(history.entriesRemoved(byLimit: 100) == 0)
        history.setLimit(100)
        #expect(history.entries.count == 1)
    }

    @Test(arguments: [(0, 10), (5, 10), (10, 10), (500, 500), (1000, 1000), (5000, 1000)])
    func limitIsClampedToAllowedRange(requested: Int, expected: Int) {
        #expect(ClipboardHistory(limit: requested).limit == expected)
        let history = ClipboardHistory()
        history.setLimit(requested)
        #expect(history.limit == expected)
    }

    @Test func clearRemovesAllEntries() {
        let history = ClipboardHistory()
        history.record(text: "item", sourceApp: nil, at: start)
        history.clear()
        #expect(history.entries.isEmpty)
    }
}

@MainActor
struct ClipboardHistoryCurrentEntryTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func startsWithoutCurrentEntry() {
        #expect(ClipboardHistory().currentEntryID == nil)
    }

    @Test func recordedTextBecomesCurrent() throws {
        let history = ClipboardHistory()
        let firstID = history.record(text: "first", sourceApp: nil, at: start)
        #expect(history.currentEntryID == firstID)
        #expect(history.entries.first?.id == firstID)

        let secondID = history.record(text: "second", sourceApp: nil, at: start + 1)
        #expect(history.currentEntryID == secondID)
    }

    @Test func repeatedTextMakesTheExistingEntryCurrent() {
        let history = ClipboardHistory()
        let firstID = history.record(text: "first", sourceApp: nil, at: start)
        history.record(text: "second", sourceApp: nil, at: start + 1)
        #expect(history.record(text: "first", sourceApp: nil, at: start + 2) == firstID)
        #expect(history.currentEntryID == firstID)
    }

    @Test func skippedCopyLeavesNoCurrentEntry() {
        let history = ClipboardHistory()
        history.record(text: "first", sourceApp: nil, at: start)
        history.markCurrentSkipped()
        #expect(history.currentEntryID == nil)
        #expect(history.entries.map(\.text) == ["first"])
    }

    @Test func clearRemovesCurrentEntry() {
        let history = ClipboardHistory()
        history.record(text: "first", sourceApp: nil, at: start)
        history.clear()
        #expect(history.currentEntryID == nil)
    }

    @Test func loweringLimitKeepsCurrentEntry() {
        let history = ClipboardHistory(limit: 20)
        var currentID: ClipboardEntry.ID?
        for index in 0..<15 {
            currentID = history.record(text: "item \(index)", sourceApp: nil, at: start + Double(index))
        }
        history.setLimit(10)
        #expect(history.currentEntryID == currentID)
    }
}

@MainActor
struct ClipboardHistoryConcealedTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")

    @Test func plainEntryIsNotConcealed() throws {
        let history = ClipboardHistory()
        history.record(text: "plain", sourceApp: nil, at: start)
        let entry = try #require(history.entries.first)
        #expect(!entry.isConcealed)
        #expect(entry.expiresAt == nil)
    }

    @Test func concealedEntryKeepsItsExpiry() throws {
        let history = ClipboardHistory()
        history.record(text: "secret", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        let entry = try #require(history.entries.first)
        #expect(entry.isConcealed)
        #expect(entry.expiresAt == start + 600)
    }

    @Test func secretCopyOfPlainTextConcealsTheEntry() throws {
        let history = ClipboardHistory()
        let id = history.record(text: "hunter2", sourceApp: notes, at: start)
        history.record(text: "other", sourceApp: nil, at: start + 1)

        history.record(text: "hunter2", sourceApp: nil, at: start + 2, concealed: true, expiresAt: start + 62)
        #expect(history.entries.count == 2)
        let entry = try #require(history.entries.first)
        #expect(entry.id == id)
        #expect(entry.isConcealed)
        #expect(entry.expiresAt == start + 62)
    }

    @Test func plainCopyOfConcealedTextStaysConcealed() throws {
        let history = ClipboardHistory()
        let id = history.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        history.record(text: "other", sourceApp: nil, at: start + 1)

        // Pasted into a note and copied from there: still a password.
        history.record(text: "hunter2", sourceApp: notes, at: start + 2)
        #expect(history.entries.count == 2)
        let entry = try #require(history.entries.first)
        #expect(entry.id == id)
        #expect(entry.isConcealed)
        #expect(entry.expiresAt == start + 600)
    }

    @Test func removeExpiredRemovesOnlyConcealedEntriesPastTheirExpiry() {
        let history = ClipboardHistory()
        history.record(text: "soon", sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)
        history.record(text: "later", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        history.record(text: "plain", sourceApp: nil, at: start)

        history.removeExpired(at: start + 59)
        #expect(history.entries.map(\.text) == ["plain", "later", "soon"])

        history.removeExpired(at: start + 60)
        #expect(history.entries.map(\.text) == ["plain", "later"])

        history.removeExpired(at: start + 100_000)
        #expect(history.entries.map(\.text) == ["plain"])
    }

    @Test func removingTheCurrentEntryLeavesNoCurrentEntry() {
        let history = ClipboardHistory()
        history.record(text: "plain", sourceApp: nil, at: start)
        history.record(text: "secret", sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)

        history.removeExpired(at: start + 60)
        #expect(history.currentEntryID == nil)
    }

    @Test func removeConcealedRemovesEveryConcealedEntry() {
        let history = ClipboardHistory()
        history.record(text: "first secret", sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)
        history.record(text: "plain", sourceApp: nil, at: start)
        history.record(text: "second secret", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)

        history.removeConcealed()
        #expect(history.entries.map(\.text) == ["plain"])
        #expect(history.currentEntryID == nil)
    }

    @Test func removeDeletesOneEntry() {
        let history = ClipboardHistory()
        let firstID = history.record(text: "first", sourceApp: nil, at: start)
        let secondID = history.record(text: "second", sourceApp: nil, at: start + 1)

        history.remove(id: firstID)
        #expect(history.entries.map(\.text) == ["second"])
        #expect(history.currentEntryID == secondID)

        history.remove(id: secondID)
        #expect(history.entries.isEmpty)
        #expect(history.currentEntryID == nil)
    }

    @Test func concealHidesAPlainEntry() throws {
        let history = ClipboardHistory()
        let id = history.record(text: "hunter2", sourceApp: nil, at: start)

        history.conceal(id: id, expiresAt: start + 600)
        let entry = try #require(history.entries.first)
        #expect(entry.isConcealed)
        #expect(entry.expiresAt == start + 600)
        #expect(history.currentEntryID == id)
    }

    @Test func concealNeverMakesAnExpiryLater() throws {
        let history = ClipboardHistory()
        let id = history.record(text: "secret", sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)

        history.conceal(id: id, expiresAt: start + 600)
        #expect(history.entries.first?.expiresAt == start + 60)

        history.conceal(id: id, expiresAt: start + 30)
        #expect(history.entries.first?.expiresAt == start + 30)
    }

    @Test func shorterLifetimeMovesLaterExpiriesEarlier() {
        let history = ClipboardHistory()
        history.record(text: "soon", sourceApp: nil, at: start, concealed: true, expiresAt: start + 30)
        history.record(text: "later", sourceApp: nil, at: start, concealed: true, expiresAt: start + 3600)
        history.record(text: "plain", sourceApp: nil, at: start)

        history.limitExpiry(to: start + 60)
        #expect(history.entries.map(\.expiresAt) == [nil, start + 60, start + 30])
    }
}
