import Foundation
import Testing

@testable import ShowMyCopy

/// ⌘⌫ deletes the selected entry and ⌘Z brings it back, without closing the window.
@MainActor
struct HistoryWindowDeleteKeyTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let history = ClipboardHistory()
    private let deleter: EntryDeleterSpy

    init() {
        deleter = EntryDeleterSpy(history: history)
    }

    /// History with "fourth" on top (current), then "third", "second" and "first".
    private func makeModel() -> HistoryWindowModel {
        for (index, text) in ["first", "second", "third", "fourth"].enumerated() {
            history.record(text: text, sourceApp: nil, at: start + Double(index))
        }
        let model = HistoryWindowModel(history: history, deleter: deleter)
        model.prepareForPresentation()
        return model
    }

    private func select(_ text: String, in model: HistoryWindowModel) throws {
        let entry = try #require(model.items.first { $0.text == text })
        while model.selectedEntry?.id != entry.id {
            model.moveSelection(.down)
        }
    }

    @Test func commandDeleteDeletesTheSelectedEntryAndSelectsTheNext() throws {
        let model = makeModel()
        try select("third", in: model)

        #expect(model.handleKey(.delete, isCaretAtEnd: true) == .handled)

        #expect(model.items.map(\.text) == ["fourth", "second", "first"])
        #expect(model.selectedEntry?.text == "second")
        #expect(deleter.deletedIDs.count == 1)
    }

    @Test func deletingTheLastRowSelectsTheOneBefore() throws {
        let model = makeModel()
        try select("first", in: model)

        _ = model.handleKey(.delete, isCaretAtEnd: true)

        #expect(model.items.map(\.text) == ["fourth", "third", "second"])
        #expect(model.selectedEntry?.text == "second")
    }

    @Test func theCurrentEntryCanBeDeleted() {
        let model = makeModel()
        #expect(model.selectedEntry?.id == model.currentEntryID)

        #expect(model.handleKey(.delete, isCaretAtEnd: false) == .handled)

        #expect(model.items.map(\.text) == ["third", "second", "first"])
        #expect(model.selectedEntry?.text == "third")
    }

    @Test func deletingEveryEntryNeverClosesTheWindow() {
        let model = makeModel()
        for _ in 0..<4 {
            #expect(model.handleKey(.delete, isCaretAtEnd: true) == .handled)
        }
        #expect(model.items.isEmpty)
        #expect(!model.showsEntries)
        #expect(model.selectedEntry == nil)

        // With nothing selected, ⌘⌫ is left to the search field.
        #expect(model.handleKey(.delete, isCaretAtEnd: true) == .ignored)
    }

    @Test func withNoMatchesTheKeyIsLeftToTheSearchField() {
        let model = makeModel()
        model.query = "nothing like it"

        #expect(model.handleKey(.delete, isCaretAtEnd: true) == .ignored)
        #expect(deleter.deletedIDs.isEmpty)
    }

    @Test func deletingAMatchSelectsTheNextMatch() throws {
        history.record(text: "apple pie", sourceApp: nil, at: start)
        history.record(text: "banana", sourceApp: nil, at: start + 1)
        history.record(text: "apple juice", sourceApp: nil, at: start + 2)
        history.record(text: "apple tart", sourceApp: nil, at: start + 3)
        let model = HistoryWindowModel(history: history, deleter: deleter)
        model.query = "apple"
        model.moveSelection(.down)
        #expect(model.selectedEntry?.text == "apple juice")

        _ = model.handleKey(.delete, isCaretAtEnd: true)

        #expect(model.items.map(\.text) == ["apple tart", "apple pie"])
        #expect(model.selectedEntry?.text == "apple pie")
    }

    @Test func deletingAnotherRowKeepsTheSelection() throws {
        let model = makeModel()
        try select("second", in: model)
        let other = try #require(model.items.first { $0.text == "third" })

        // From the row's context menu or VoiceOver.
        model.delete(other)

        #expect(model.items.map(\.text) == ["fourth", "second", "first"])
        #expect(model.selectedEntry?.text == "second")
    }

    @Test func deletingThePreviewedEntryClosesThePreview() {
        let model = makeModel()
        _ = model.handleKey(.right, isCaretAtEnd: true)
        #expect(model.preview.isOpen)

        _ = model.handleKey(.delete, isCaretAtEnd: true)

        #expect(!model.preview.isOpen)
        #expect(model.selectedEntry?.text == "third")
    }

    @Test func aRevealedPasswordIsHiddenWhenItComesBack() throws {
        let id = history.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        let model = HistoryWindowModel(history: history, deleter: deleter)
        model.toggleReveal(id)
        let password = try #require(history.entries.first)

        model.delete(password)
        _ = model.handleKey(.undo, isCaretAtEnd: true)

        #expect(model.items.map(\.id) == [id])
        #expect(!model.isRevealed(id))
    }

    // MARK: - Undo

    @Test func commandZBringsBackTheDeletedEntryAndSelectsIt() throws {
        let model = makeModel()
        try select("third", in: model)
        _ = model.handleKey(.delete, isCaretAtEnd: true)

        #expect(model.handleKey(.undo, isCaretAtEnd: true) == .handled)

        #expect(model.items.map(\.text) == ["fourth", "third", "second", "first"])
        #expect(model.selectedEntry?.text == "third")
    }

    @Test func commandZWithNothingToBringBackUndoesTyping() {
        let model = makeModel()
        #expect(model.handleKey(.undo, isCaretAtEnd: true) == .ignored)

        _ = model.handleKey(.delete, isCaretAtEnd: true)
        _ = model.handleKey(.undo, isCaretAtEnd: true)
        #expect(model.handleKey(.undo, isCaretAtEnd: true) == .ignored)
    }

    @Test func undoEndsWhenTheWindowOpensAgain() {
        let model = makeModel()
        _ = model.handleKey(.delete, isCaretAtEnd: true)
        let finished = deleter.finishCount

        model.prepareForPresentation()

        #expect(deleter.finishCount == finished + 1)
        #expect(model.handleKey(.undo, isCaretAtEnd: true) == .ignored)
        #expect(model.items.count == 3)
    }

    /// The real deleter polls first, so a copy made just before ⌘⌫ is listed at the top meanwhile. The selection
    /// still moves to the deleted entry's neighbour.
    @Test func aCopyRecordedWhileDeletingDoesNotMoveTheSelectionAway() throws {
        let pasteboard = FakePasteboard()
        let monitor = MonitorFactory.make(pasteboard: pasteboard, history: history)
        for text in ["first", "second", "third"] {
            pasteboard.copy(text)
            monitor.poll()
        }
        let model = HistoryWindowModel(
            history: history,
            deleter: EntryDeleter(
                history: history, pasteboard: pasteboard, monitor: monitor, blobs: nil, now: { MonitorFactory.date }))
        model.prepareForPresentation()
        try select("second", in: model)
        pasteboard.copy("just copied")

        _ = model.handleKey(.delete, isCaretAtEnd: true)

        #expect(model.items.map(\.text) == ["just copied", "third", "first"])
        #expect(model.selectedEntry?.text == "first")
        #expect(pasteboard.text == "just copied")
    }
}
