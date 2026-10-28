import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct SearchKeyTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")
    private let onePassword = SourceApp(bundleIdentifier: "com.1password.1password", name: "1Password")

    @Test func foldsCaseAndDiacritics() {
        #expect(SearchKey.fold("Café AU Lait") == "cafe au lait")
        // "é" written as "e" and a combining accent folds the same way.
        #expect(SearchKey.fold("Cafe\u{301}") == "cafe")
    }

    @Test func entryKeepsItsTextFoldedForSearch() {
        let entry = ClipboardEntry(text: "Café AU Lait", date: date, sourceApp: notes)
        #expect(entry.searchKey == "cafe au lait")
        #expect(entry.sourceAppSearchKey == "notes")
    }

    @Test func keyCoversOnlyTheStartOfLongText() throws {
        let text = String(repeating: "a", count: SearchKey.searchedCharacters) + "Z"
        let entry = ClipboardEntry(text: text, date: date, sourceApp: nil)
        let key = try #require(entry.searchKey)
        #expect(key.count == SearchKey.searchedCharacters)
        #expect(!key.contains("z"))
    }

    @Test func entryWithoutAppNameHasNoAppKey() {
        let entry = ClipboardEntry(text: "text", date: date, sourceApp: SourceApp(bundleIdentifier: "x.y", name: nil))
        #expect(entry.sourceAppSearchKey == nil)
    }

    @Test func concealedEntryHasNoTextKey() throws {
        let store = InMemoryHistoryStore()
        store.record(text: "Hunter2", sourceApp: onePassword, at: date, concealed: true, expiresAt: date + 60)
        let entry = try #require(store.entries.first)
        #expect(entry.searchKey == nil)
        #expect(entry.sourceAppSearchKey == "1password")
    }

    @Test func concealingAnEntryDropsItsTextKey() throws {
        let store = InMemoryHistoryStore()
        let id = store.record(text: "Hunter2", sourceApp: notes, at: date)
        #expect(store.entries.first?.searchKey == "hunter2")

        store.conceal(id: id, expiresAt: date + 60)
        let entry = try #require(store.entries.first)
        #expect(entry.searchKey == nil)
        #expect(entry.sourceAppSearchKey == "notes")
    }

    @Test func appKeyFollowsTheSourceApp() throws {
        let store = InMemoryHistoryStore()
        store.record(text: "same", sourceApp: notes, at: date)
        store.record(text: "same", sourceApp: SourceApp(bundleIdentifier: "com.apple.Safari", name: "Safari"), at: date)
        let entry = try #require(store.entries.first)
        #expect(entry.sourceAppSearchKey == "safari")
    }
}
