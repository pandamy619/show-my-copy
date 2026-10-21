import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct HistoryWindowModelTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")
    private let safari = SourceApp(bundleIdentifier: "com.apple.Safari", name: "Safari")

    /// History with "third" (Safari) on top, then "second" (Notes), then "first" (no app).
    private func makeModel(texts: [String] = ["first", "second", "third"]) -> HistoryWindowModel {
        let history = ClipboardHistory()
        let apps = [nil, notes, safari]
        for (index, text) in texts.enumerated() {
            history.record(text: text, sourceApp: apps[index % apps.count], at: start + Double(index))
        }
        return HistoryWindowModel(history: history)
    }

    @Test func emptyQueryShowsAllEntriesNewestFirst() {
        let model = makeModel()
        #expect(model.items.map(\.text) == ["third", "second", "first"])
        #expect(model.currentEntryID == model.items.first?.id)
    }

    @Test func currentEntryIsWhatTheHistoryMarksAsCurrent() {
        let model = makeModel()
        #expect(model.currentEntryID == model.history.currentEntryID)

        // A skipped copy (a password, an image) replaced the pasteboard: no entry is on it now.
        model.history.markCurrentSkipped()
        #expect(model.currentEntryID == nil)
        #expect(model.items.count == 3)
    }

    @Test func emptyHistoryHasNoSelection() {
        let model = HistoryWindowModel(history: ClipboardHistory())
        #expect(model.items.isEmpty)
        #expect(model.selectedIndex == nil)
        #expect(model.selectedEntry == nil)
        model.moveSelection(.down)
        model.moveSelection(.up)
        #expect(model.selectedEntry == nil)
    }

    @Test func firstEntryIsSelectedInitially() {
        let model = makeModel()
        #expect(model.selectedIndex == 0)
        #expect(model.selectedEntry?.text == "third")
    }

    @Test func moveSelectionIsClampedToTheList() {
        let model = makeModel()
        model.moveSelection(.up)
        #expect(model.selectedIndex == 0)

        model.moveSelection(.down)
        model.moveSelection(.down)
        #expect(model.selectedEntry?.text == "first")
        model.moveSelection(.down)
        #expect(model.selectedIndex == 2)

        model.moveSelection(.up)
        #expect(model.selectedEntry?.text == "second")
    }

    @Test(arguments: [
        ("SECOND", ["second"]),
        ("cafe", ["Café au lait"]),
        ("CAFÉ", ["Café au lait"]),
        ("  sec  ", ["second"]),
        ("nothing like this", []),
    ])
    func filtersTextIgnoringCaseAndDiacritics(query: String, expected: [String]) {
        let model = makeModel(texts: ["first", "second", "Café au lait"])
        model.query = query
        #expect(model.items.map(\.text) == expected)
    }

    @Test func filtersBySourceAppName() {
        let model = makeModel()
        model.query = "safari"
        #expect(model.items.map(\.text) == ["third"])
        model.query = "NOTES"
        #expect(model.items.map(\.text) == ["second"])
    }

    @Test func changingQueryResetsSelectionToFirstItem() {
        let model = makeModel()
        model.moveSelection(.down)
        model.moveSelection(.down)
        model.query = "e"
        #expect(model.selectedIndex == 0)
        #expect(model.selectedEntry?.text == "second")
    }

    @Test func settingTheSameQueryKeepsSelection() {
        let model = makeModel()
        model.query = "i"
        model.moveSelection(.down)
        model.query = "i"
        #expect(model.selectedIndex == 1)
    }

    @Test func selectionStaysInsideListWhenHistoryShrinks() {
        let model = makeModel()
        model.moveSelection(.down)
        model.moveSelection(.down)
        model.history.clear()
        model.history.record(text: "only", sourceApp: nil, at: start)
        #expect(model.selectedIndex == 0)
        #expect(model.selectedEntry?.text == "only")
    }

    @Test func selectionFollowsItsEntryWhenANewCopyArrives() {
        let model = makeModel()
        model.moveSelection(.down)
        #expect(model.selectedEntry?.text == "second")

        model.history.record(text: "fresh", sourceApp: nil, at: start + 10)
        #expect(model.selectedEntry?.text == "second")
        #expect(model.selectedIndex == 2)
    }

    @Test func firstEntryStaysSelectedWhenANewCopyArrives() {
        let model = makeModel()
        model.prepareForPresentation()

        model.history.record(text: "fresh", sourceApp: nil, at: start + 10)
        #expect(model.selectedEntry?.text == "third")
        #expect(model.selectedIndex == 1)
    }

    @Test func selectionFollowsItsEntryWhenItMovesToTheTop() {
        let model = makeModel()
        model.moveSelection(.down)
        model.moveSelection(.down)
        #expect(model.selectedEntry?.text == "first")

        model.history.record(text: "first", sourceApp: nil, at: start + 10)
        #expect(model.selectedEntry?.text == "first")
        #expect(model.selectedIndex == 0)
    }

    @Test func selectionStaysOnItsEntryWhenAnotherEntryMovesToTheTop() {
        let model = makeModel()
        model.moveSelection(.down)

        model.history.record(text: "first", sourceApp: nil, at: start + 10)
        #expect(model.items.map(\.text) == ["first", "third", "second"])
        #expect(model.selectedEntry?.text == "second")
    }

    @Test func selectionKeepsItsRowWhenItsEntryIsRemoved() {
        let model = makeModel(texts: ["first", "second", "third", "fourth"])
        model.moveSelection(.down)
        model.moveSelection(.down)
        #expect(model.selectedEntry?.text == "second")

        // The selected entry is gone, so the row it was on stays selected.
        model.history.clear()
        for text in ["a", "b", "c", "d"] {
            model.history.record(text: text, sourceApp: nil, at: start)
        }
        #expect(model.selectedIndex == 2)
        #expect(model.selectedEntry?.text == "b")
    }

    @Test func movingFromAFollowedEntryStartsAtItsNewRow() {
        let model = makeModel()
        model.moveSelection(.down)
        model.history.record(text: "fresh", sourceApp: nil, at: start + 10)

        model.moveSelection(.down)
        #expect(model.selectedEntry?.text == "first")
        model.moveSelection(.up)
        model.moveSelection(.up)
        #expect(model.selectedEntry?.text == "third")
    }

    @Test func prepareForPresentationClearsQueryAndSelectsFirst() {
        let model = makeModel()
        model.query = "i"
        model.moveSelection(.down)
        let count = model.presentationCount

        model.prepareForPresentation()
        #expect(model.query.isEmpty)
        #expect(model.selectedIndex == 0)
        #expect(model.items.count == 3)
        #expect(model.presentationCount == count + 1)
    }

    @Test func presentationSelectsTheNewestEntryAfterTheHistoryChanged() {
        let model = makeModel()
        model.moveSelection(.down)
        model.history.record(text: "fresh", sourceApp: nil, at: start + 10)

        model.prepareForPresentation()
        #expect(model.selectedIndex == 0)
        #expect(model.selectedEntry?.text == "fresh")
    }
}

@MainActor
struct HistoryWindowModelConcealedTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let onePassword = SourceApp(bundleIdentifier: "com.1password.1password", name: "1Password")
    private let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")

    /// "hunter2" is a concealed entry from 1Password, "hunter2 notes" a plain entry from Notes.
    private func makeModel() -> HistoryWindowModel {
        let history = ClipboardHistory()
        history.record(text: "hunter2 notes", sourceApp: notes, at: start)
        history.record(
            text: "hunter2", sourceApp: onePassword, at: start + 1, concealed: true, expiresAt: start + 600)
        return HistoryWindowModel(history: history)
    }

    @Test func searchDoesNotLookInsideConcealedEntries() {
        let model = makeModel()
        model.query = "hunter"
        #expect(model.items.map(\.text) == ["hunter2 notes"])
    }

    @Test func concealedEntryMatchesItsSourceApp() {
        let model = makeModel()
        model.query = "1password"
        #expect(model.items.map(\.text) == ["hunter2"])
    }

    @Test func toggleRevealShowsAndHidesOneEntry() throws {
        let model = makeModel()
        let concealed = try #require(model.items.first)
        #expect(!model.isRevealed(concealed.id))

        model.toggleReveal(concealed.id)
        #expect(model.isRevealed(concealed.id))

        model.toggleReveal(concealed.id)
        #expect(!model.isRevealed(concealed.id))
    }

    @Test func presentationHidesRevealedEntriesAgain() throws {
        let model = makeModel()
        let concealed = try #require(model.items.first)
        model.toggleReveal(concealed.id)

        model.prepareForPresentation()
        #expect(!model.isRevealed(concealed.id))
    }

    @Test func concealAllHidesEveryRevealedEntry() throws {
        let model = makeModel()
        let concealed = try #require(model.items.first)
        model.toggleReveal(concealed.id)

        model.concealAll()
        #expect(!model.isRevealed(concealed.id))
    }
}

@MainActor
struct HistoryWindowModelSearchTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")

    @Test func searchLooksOnlyAtTheStartOfLongText() {
        let history = ClipboardHistory()
        let text = String(repeating: "a", count: SearchKey.searchedCharacters) + "needle"
        history.record(text: text, sourceApp: nil, at: start)
        let model = HistoryWindowModel(history: history)
        model.query = "needle"
        #expect(model.items.isEmpty)
    }

    @Test func entryConcealedLaterMatchesOnlyByItsAppName() {
        let history = ClipboardHistory()
        let id = history.record(text: "hunter2", sourceApp: notes, at: start)
        let model = HistoryWindowModel(history: history)
        model.query = "hunter"
        #expect(model.items.map(\.id) == [id])

        // The clipboard was cleared soon after the copy, so the entry turned out to be a password.
        history.conceal(id: id, expiresAt: start + 60)
        #expect(model.items.isEmpty)
        model.query = "notes"
        #expect(model.items.map(\.id) == [id])
    }
}

@MainActor
struct HistoryWindowModelCacheTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeModel() -> HistoryWindowModel {
        let history = ClipboardHistory()
        for (index, text) in ["first", "second", "third"].enumerated() {
            history.record(text: text, sourceApp: nil, at: start + Double(index))
        }
        return HistoryWindowModel(history: history)
    }

    @Test func emptyQueryDoesNotFilter() {
        let model = makeModel()
        _ = model.items
        _ = model.selectedEntry
        #expect(model.filterCount == 0)
    }

    @Test func readingTheItemsAgainDoesNotFilterAgain() {
        let model = makeModel()
        model.query = "i"
        let count = model.filterCount
        #expect(model.items.map(\.text) == ["third", "first"])
        _ = model.selectedIndex
        _ = model.selectedEntry
        model.moveSelection(.down)
        #expect(model.items.map(\.text) == ["third", "first"])
        #expect(model.filterCount == count)
    }

    @Test func changingTheQueryFiltersAgain() {
        let model = makeModel()
        model.query = "i"
        _ = model.items
        let count = model.filterCount
        model.query = "ir"
        #expect(model.items.map(\.text) == ["third", "first"])
        model.query = "fir"
        #expect(model.items.map(\.text) == ["first"])
        #expect(model.filterCount > count)
    }

    @Test func newCopyIsFoundWithTheSameQuery() {
        let model = makeModel()
        model.query = "fresh"
        #expect(model.items.isEmpty)

        model.history.record(text: "fresh", sourceApp: nil, at: start + 10)
        #expect(model.items.map(\.text) == ["fresh"])
    }

    @Test func changedEntryIsFilteredAgainWhenCountAndOrderStay() throws {
        let model = makeModel()
        model.query = "second"
        let entry = try #require(model.items.first)

        // Concealing keeps the number and order of the entries, so only the revision tells the cache.
        model.history.conceal(id: entry.id, expiresAt: start + 60)
        #expect(model.items.isEmpty)
    }

    @Test func removedEntryLeavesTheFilteredList() {
        let model = makeModel()
        model.query = "i"
        #expect(model.items.count == 2)
        model.history.clear()
        #expect(model.items.isEmpty)
    }
}
