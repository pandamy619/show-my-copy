import Foundation
import Testing

@testable import ShowMyCopy

/// ⌘P pins and unpins the selected entry; the window lists the entry on the clipboard, then the pinned entries in
/// the order they were pinned, then the rest.
@MainActor
struct HistoryWindowPinTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let clock = ManualDate(Date(timeIntervalSince1970: 1_790_000_100))
    private let history: InMemoryHistoryStore
    private let deleter: EntryDeleterSpy

    init() {
        history = InMemoryHistoryStore(now: clock.read)
        deleter = EntryDeleterSpy(history: history)
    }

    /// "first" to "fourth", "fourth" on the clipboard.
    private func makeModel() -> HistoryWindowModel {
        for (index, text) in ["first", "second", "third", "fourth"].enumerated() {
            history.record(text: text, sourceApp: nil, at: start + Double(index))
        }
        let model = HistoryWindowModel(history: history, deleter: deleter)
        model.prepareForPresentation()
        return model
    }

    private func id(of text: String) throws -> ClipboardEntry.ID {
        try #require(history.entries.first { $0.text == text }).id
    }

    private func pin(_ texts: String...) throws {
        for text in texts {
            clock.advance(by: 1)
            history.setPinned(true, id: try id(of: text))
        }
    }

    private func select(_ text: String, in model: HistoryWindowModel) throws {
        let entry = try #require(model.items.first { $0.text == text })
        while model.selectedEntry?.id != entry.id {
            model.moveSelection(.down)
        }
    }

    @Test func pinnedEntriesAreListedUnderTheClipboardInTheOrderTheyWerePinned() throws {
        let model = makeModel()
        try pin("second", "first")

        let sections = model.sections
        #expect(sections.current?.text == "fourth")
        #expect(sections.pinned.map(\.text) == ["second", "first"])
        #expect(sections.history.map(\.text) == ["third"])
        #expect(model.items.map(\.text) == ["fourth", "second", "first", "third"])
    }

    @Test func aNewCopyGoesOnTheClipboardRowAboveThePinnedOnes() throws {
        let model = makeModel()
        try pin("first")

        history.record(text: "fresh", sourceApp: nil, at: start + 200)

        #expect(model.sections.current?.text == "fresh")
        #expect(model.items.map(\.text) == ["fresh", "first", "fourth", "third", "second"])
    }

    @Test func aPinnedEntryOnTheClipboardStaysInItsPlace() throws {
        let model = makeModel()
        try pin("second", "first")

        history.record(text: "second", sourceApp: nil, at: start + 10)

        #expect(model.currentEntryID == (try id(of: "second")))
        #expect(model.sections.current == nil)
        #expect(model.sections.pinned.map(\.text) == ["second", "first"])
        #expect(model.items.map(\.text) == ["second", "first", "fourth", "third"])
    }

    @Test func searchFiltersEverySection() throws {
        let model = makeModel()
        try pin("first", "second")

        model.query = "ir"

        #expect(model.sections.current == nil)
        #expect(model.sections.pinned.map(\.text) == ["first"])
        #expect(model.sections.history.map(\.text) == ["third"])
        #expect(model.selectedEntry?.text == "first")
    }

    @Test func arrowKeysMoveAcrossTheSections() throws {
        let model = makeModel()
        try pin("second")
        #expect(model.selectedEntry?.text == "fourth")

        var visited = [model.selectedEntry?.text]
        for _ in 0..<4 {
            #expect(model.handleKey(.down, isCaretAtEnd: true) == .handled)
            visited.append(model.selectedEntry?.text)
        }
        #expect(visited == ["fourth", "second", "third", "first", "first"])

        _ = model.handleKey(.up, isCaretAtEnd: true)
        _ = model.handleKey(.up, isCaretAtEnd: true)
        #expect(model.selectedEntry?.text == "second")
    }

    @Test func commandPPinsTheSelectedEntryAndKeepsItSelected() throws {
        let model = makeModel()
        try select("second", in: model)

        #expect(model.handleKey(.pin, isCaretAtEnd: true) == .handled)

        #expect(model.sections.pinned.map(\.text) == ["second"])
        #expect(model.items.map(\.text) == ["fourth", "second", "third", "first"])
        #expect(model.selectedEntry?.text == "second")
    }

    @Test func commandPAgainUnpinsItToTheTopOfTheHistory() throws {
        let model = makeModel()
        try select("first", in: model)
        _ = model.handleKey(.pin, isCaretAtEnd: true)
        clock.advance(by: 60)

        #expect(model.handleKey(.pin, isCaretAtEnd: true) == .handled)

        #expect(model.sections.pinned.isEmpty)
        // The clipboard row stays on top; the unpinned entry heads the history.
        #expect(model.items.map(\.text) == ["fourth", "first", "third", "second"])
        #expect(model.selectedEntry?.text == "first")
    }

    @Test func pinningTheEntryOnTheClipboardMovesItIntoThePinnedSection() throws {
        let model = makeModel()
        #expect(model.handleKey(.pin, isCaretAtEnd: true) == .handled)

        #expect(model.sections.current == nil)
        #expect(model.sections.pinned.map(\.text) == ["fourth"])
        #expect(model.selectedEntry?.text == "fourth")

        _ = model.handleKey(.pin, isCaretAtEnd: true)
        #expect(model.sections.current?.text == "fourth")
        #expect(model.selectedEntry?.text == "fourth")
    }

    @Test func commandPNeverPinsAPassword() throws {
        history.record(text: "plain", sourceApp: nil, at: start)
        history.record(text: "hunter2", sourceApp: nil, at: start + 1, concealed: true, expiresAt: start + 600)
        let model = HistoryWindowModel(history: history, deleter: deleter)
        model.prepareForPresentation()
        let password = try #require(model.selectedEntry)
        #expect(!HistoryWindowModel.canPin(password))

        // Handled all the same, so ⌘P never reaches Print or the search field.
        #expect(model.handleKey(.pin, isCaretAtEnd: true) == .handled)
        model.togglePin(password)

        #expect(history.entries.allSatisfy { !$0.isPinned })
        #expect(HistoryWindowModel.canPin(try #require(history.entries.last)))
    }

    @Test func commandPWithNothingSelectedIsHandled() {
        let model = HistoryWindowModel(history: history, deleter: deleter)
        #expect(model.handleKey(.pin, isCaretAtEnd: true) == .handled)

        let filled = makeModel()
        filled.query = "nothing like it"
        #expect(filled.handleKey(.pin, isCaretAtEnd: true) == .handled)
        #expect(history.entries.allSatisfy { !$0.isPinned })
    }

    @Test func aStaleRowTogglesThePinTheEntryHasNow() throws {
        let model = makeModel()
        let row = try #require(model.items.last)
        model.togglePin(row)
        // The row was made before the pin: it still says unpinned.
        model.togglePin(row)
        #expect(history.entries.allSatisfy { !$0.isPinned })
    }

    @Test func commandDeleteDeletesAPinnedEntryAndSelectsTheNextRow() throws {
        let model = makeModel()
        try pin("second", "first")
        try select("second", in: model)

        #expect(model.handleKey(.delete, isCaretAtEnd: true) == .handled)

        #expect(model.items.map(\.text) == ["fourth", "first", "third"])
        #expect(model.selectedEntry?.text == "first")

        #expect(model.handleKey(.undo, isCaretAtEnd: true) == .handled)
        #expect(model.sections.pinned.map(\.text) == ["second", "first"])
        #expect(model.selectedEntry?.text == "second")
    }

    @Test func theSectionsAreReusedUntilTheHistoryChanges() throws {
        let model = makeModel()
        try pin("first")
        model.query = "i"
        let count = model.filterCount
        _ = model.sections
        _ = model.items
        model.moveSelection(.down)
        #expect(model.filterCount == count)

        clock.advance(by: 1)
        history.setPinned(false, id: try id(of: "first"))
        #expect(model.sections.pinned.isEmpty)
        #expect(model.filterCount > count)
    }
}

/// ⌘P reaches the open history window as a key equivalent, before the search field or Print.
@MainActor
struct HistoryWindowControllerPinTests {
    private let pasteboard = FakePasteboard()
    private let history = InMemoryHistoryStore()

    @Test func commandPPinsTheSelectedEntryWhileTheWindowIsOpen() {
        let monitor = MonitorFactory.make(pasteboard: pasteboard, history: history)
        pasteboard.copy("older")
        monitor.poll()
        let controller = HistoryWindowController(
            model: HistoryWindowModel(history: history),
            copier: EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor),
            monitor: monitor,
            onOpenSettings: {}
        )
        #expect(!controller.handleCommandKey(.pin))

        controller.show()
        #expect(controller.handleCommandKey(.pin))

        #expect(controller.isVisible)
        #expect(history.entries.first?.isPinned == true)
        #expect(controller.model.sections.pinned.map(\.text) == ["older"])
        controller.hide()
    }
}
