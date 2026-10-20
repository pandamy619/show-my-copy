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

    @Test func selectByID() throws {
        let model = makeModel()
        let second = try #require(model.items.first { $0.text == "second" })
        model.select(id: second.id)
        #expect(model.selectedEntry == second)

        model.select(id: UUID())
        #expect(model.selectedEntry == second)
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
}
