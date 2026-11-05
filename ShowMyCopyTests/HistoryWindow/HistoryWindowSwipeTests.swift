import Foundation
import Testing

@testable import ShowMyCopy

/// Swiping a row in the history window opens it as wide as its action buttons; a full swipe deletes like ⌘⌫, also
/// pinned entries and passwords, and the swiped row closes when the user types, presses a key, changes the selection
/// or clicks a row.
@MainActor
struct HistoryWindowSwipeTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let history = InMemoryHistoryStore()
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

    /// How far a full swipe goes on a row with Show Preview, Pin and Delete.
    private let fullSwipe = RowSwipe.fullSwipeThreshold(actionsWidth: RowSwipe.actionsWidth(buttonCount: 3))

    private func entry(_ text: String, in model: HistoryWindowModel) throws -> ClipboardEntry {
        try #require(model.items.first { $0.text == text })
    }

    /// A trackpad swipe of `distance` points to the left over the row of `entry`, in one step.
    private func swipeLeft(_ distance: CGFloat, on entry: ClipboardEntry, in model: HistoryWindowModel) {
        _ = model.swipeScrolled(RowSwipe.Scroll(phase: .began), on: entry)
        _ = model.swipeScrolled(RowSwipe.Scroll(phase: .changed, deltaX: -distance), on: entry)
        _ = model.swipeScrolled(RowSwipe.Scroll(phase: .ended), on: entry)
    }

    // MARK: - Deleting

    @Test func aFullSwipeDeletesTheEntryAndKeepsTheSelection() throws {
        let model = makeModel()
        let third = try entry("third", in: model)

        swipeLeft(fullSwipe, on: third, in: model)

        #expect(deleter.deletedIDs == [third.id])
        #expect(model.items.map(\.text) == ["fourth", "second", "first"])
        #expect(model.selectedEntry?.text == "fourth")
        #expect(model.swipe.swipedRowID == nil)
    }

    @Test func aShorterSwipeOnlyOpensTheRow() throws {
        let model = makeModel()
        let third = try entry("third", in: model)

        swipeLeft(fullSwipe - 1, on: third, in: model)

        #expect(deleter.deletedIDs.isEmpty)
        #expect(model.swipe.swipedRowID == third.id)
    }

    @Test func aSwipeOpensTheRowAsWideAsItsButtons() throws {
        let model = makeModel()
        let third = try entry("third", in: model)

        swipeLeft(RowSwipe.holdThreshold, on: third, in: model)

        #expect(
            model.swipe.offset(of: third.id) == RowSwipe.actionsWidth(buttonCount: RowAction.offers(for: third).count))
    }

    @Test func theButtonDeletesTheSwipedEntryAndClosesTheRow() throws {
        let model = makeModel()
        let third = try entry("third", in: model)
        swipeLeft(RowSwipe.holdThreshold, on: third, in: model)

        // The Delete button runs the same action as the context menu, which deletes like ⌘⌫.
        model.perform(.delete, on: third)

        #expect(deleter.deletedIDs == [third.id])
        #expect(model.swipe.swipedRowID == nil)
    }

    @Test func commandZBringsBackASwipedEntry() throws {
        let model = makeModel()
        let third = try entry("third", in: model)
        swipeLeft(fullSwipe, on: third, in: model)

        #expect(model.handleKey(.undo, isCaretAtEnd: true) == .handled)

        #expect(model.items.map(\.text) == ["fourth", "third", "second", "first"])
        #expect(model.selectedEntry?.text == "third")
    }

    @Test func aPinnedEntryIsDeletedBySwipingAndComesBackPinned() throws {
        let model = makeModel()
        let second = try entry("second", in: model)
        model.togglePin(second)
        let pinned = try #require(model.sections.pinned.first)

        swipeLeft(fullSwipe, on: pinned, in: model)
        #expect(model.sections.pinned.isEmpty)
        #expect(!model.items.contains { $0.id == second.id })

        _ = model.handleKey(.undo, isCaretAtEnd: true)
        #expect(model.sections.pinned.map(\.id) == [second.id])
    }

    @Test func aPasswordIsDeletedBySwipingWithoutBeingRevealed() throws {
        let id = history.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        let model = HistoryWindowModel(history: history, deleter: deleter)
        model.prepareForPresentation()
        let password = try #require(model.items.first)

        swipeLeft(RowSwipe.holdThreshold, on: password, in: model)
        #expect(model.swipe.swipedRowID == id)
        #expect(!model.isRevealed(id))
        // Pin and Delete: a password has no preview.
        #expect(model.swipe.offset(of: id) == RowSwipe.actionsWidth(buttonCount: 2))

        swipeLeft(
            RowSwipe.fullSwipeThreshold(actionsWidth: RowSwipe.actionsWidth(buttonCount: 2)), on: password, in: model)
        #expect(deleter.deletedIDs == [id])
        #expect(model.items.isEmpty)
    }

    /// The real deleter empties the clipboard that holds the swiped entry, as for ⌘⌫.
    @Test func swipingTheCurrentEntryEmptiesTheClipboard() throws {
        let pasteboard = FakePasteboard()
        let monitor = MonitorFactory.make(pasteboard: pasteboard, history: history)
        for text in ["older", "on the clipboard"] {
            pasteboard.copy(text)
            monitor.poll()
        }
        let model = HistoryWindowModel(
            history: history,
            deleter: EntryDeleter(
                history: history, pasteboard: pasteboard, monitor: monitor, blobs: nil, now: { MonitorFactory.date }))
        model.prepareForPresentation()
        let current = try #require(model.sections.current)

        swipeLeft(fullSwipe, on: current, in: model)

        #expect(model.items.map(\.text) == ["older"])
        #expect(pasteboard.text == nil)
    }

    // MARK: - Closing

    @Test func typingClosesTheSwipedRow() throws {
        let model = makeModel()
        try swipeLeft(60, on: entry("third", in: model), in: model)

        model.query = "t"

        #expect(model.swipe.swipedRowID == nil)
    }

    @Test func aKeyClosesTheSwipedRow() throws {
        let model = makeModel()
        try swipeLeft(60, on: entry("third", in: model), in: model)

        _ = model.handleKey(.left, isCaretAtEnd: false)

        #expect(model.swipe.swipedRowID == nil)
    }

    @Test func anotherSelectionClosesTheSwipedRow() throws {
        let model = makeModel()
        try swipeLeft(60, on: entry("third", in: model), in: model)

        model.moveSelection(.down)

        #expect(model.swipe.swipedRowID == nil)
    }

    @Test func aClickOnARowOnlyClosesTheSwipedRow() throws {
        let model = makeModel()
        try swipeLeft(60, on: entry("third", in: model), in: model)

        #expect(model.closeSwipedRow())
        #expect(model.swipe.swipedRowID == nil)
        // The next click chooses as usual.
        #expect(!model.closeSwipedRow())
    }

    @Test func aClickDoesNotWaitForARowThatIsGone() throws {
        let model = makeModel()
        let third = try entry("third", in: model)
        swipeLeft(60, on: third, in: model)

        // Removed meanwhile, for example a password whose time is up.
        history.remove(id: third.id)

        #expect(!model.closeSwipedRow())
    }

    @Test func theWindowOpensWithNoRowSwiped() throws {
        let model = makeModel()
        try swipeLeft(60, on: entry("fourth", in: model), in: model)

        model.prepareForPresentation()

        #expect(model.swipe.swipedRowID == nil)
    }

    @Test func scrollingTheListClosesTheSwipedRow() throws {
        let model = makeModel()
        try swipeLeft(60, on: entry("third", in: model), in: model)

        let first = try entry("first", in: model)
        #expect(!model.swipeScrolled(RowSwipe.Scroll(phase: .began), on: first))
        #expect(!model.swipeScrolled(RowSwipe.Scroll(phase: .changed, deltaY: -12), on: first))

        #expect(model.swipe.swipedRowID == nil)
        #expect(deleter.deletedIDs.isEmpty)
    }
}
