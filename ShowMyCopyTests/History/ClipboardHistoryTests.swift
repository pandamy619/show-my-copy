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
