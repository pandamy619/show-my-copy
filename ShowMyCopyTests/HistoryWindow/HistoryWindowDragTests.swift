import AppKit
import Foundation
import Testing

@testable import ShowMyCopy

/// Dragging an entry out of the history window: the panel stays open while the user drags, closes after a drop in
/// another app and stays after a cancelled drag. The clipboard and the history are never touched.
///
/// One test at a time, like `HistoryWindowControllerTests`: only one panel is ever open in the app.
@MainActor
@Suite(.serialized)
struct HistoryWindowDragTests {
    private let pasteboard = FakePasteboard()
    private let history = InMemoryHistoryStore()
    private let monitor: ClipboardMonitor

    init() {
        monitor = MonitorFactory.make(pasteboard: pasteboard, history: history)
    }

    /// What AppKit tells the window controller when the panel loses key focus, such as for a click in another app.
    private static let resignedKey = Notification(name: NSWindow.didResignKeyNotification)

    /// An open history window listing "newer" (on the clipboard) and "older".
    private func shownController() -> HistoryWindowController {
        for text in ["older", "newer"] {
            pasteboard.copy(text)
            monitor.poll()
        }
        let controller = HistoryWindowController(
            model: HistoryWindowModel(history: history),
            copier: EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor),
            paster: EntryPasterSpy(),
            monitor: monitor,
            onOpenSettings: {}
        )
        controller.show()
        return controller
    }

    @Test func thePanelStaysOpenWhileDragging() {
        let controller = shownController()

        controller.rowDrag(.began)
        controller.windowDidResignKey(Self.resignedKey)

        #expect(controller.isVisible)
    }

    @Test func aDropInAnotherAppClosesThePanel() {
        let controller = shownController()

        controller.rowDrag(.began)
        controller.windowDidResignKey(Self.resignedKey)
        controller.rowDrag(.ended(dropped: true))

        #expect(!controller.isVisible)
    }

    @Test func aDropWhileThePanelKeptKeyFocusClosesIt() {
        let controller = shownController()

        controller.rowDrag(.began)
        controller.rowDrag(.ended(dropped: true))

        #expect(!controller.isVisible)
    }

    @Test func aCancelledDragKeepsThePanelOpen() {
        let controller = shownController()

        controller.rowDrag(.began)
        controller.windowDidResignKey(Self.resignedKey)
        controller.rowDrag(.ended(dropped: false))

        #expect(controller.isVisible)
    }

    @Test func afterACancelledDragLosingKeyFocusClosesThePanel() {
        let controller = shownController()
        controller.rowDrag(.began)
        controller.rowDrag(.ended(dropped: false))

        controller.windowDidResignKey(Self.resignedKey)

        #expect(!controller.isVisible)
    }

    @Test func aDragDoesNotTouchTheClipboardOrTheHistory() throws {
        let controller = shownController()
        let entries = history.entries
        let changeCount = pasteboard.changeCount

        controller.rowDrag(.began)
        controller.rowDrag(.ended(dropped: true))

        #expect(pasteboard.changeCount == changeCount)
        #expect(pasteboard.writtenTexts.isEmpty)
        #expect(pasteboard.string() == "newer")
        #expect(history.entries == entries)
        #expect(controller.model.currentEntryID == entries.first?.id)
    }

    @Test func aDragFromAnEarlierWindowDoesNotCloseTheNextOne() {
        let controller = shownController()
        controller.rowDrag(.began)
        controller.hide()
        controller.show()

        controller.rowDrag(.ended(dropped: true))

        #expect(controller.isVisible)
    }

    @Test func draggingClosesASwipedRow() throws {
        let controller = shownController()
        let older = try #require(controller.model.items.last)
        _ = controller.model.swipeScrolled(RowSwipe.Scroll(phase: .began), on: older)
        _ = controller.model.swipeScrolled(RowSwipe.Scroll(phase: .changed, deltaX: -60), on: older)
        _ = controller.model.swipeScrolled(RowSwipe.Scroll(phase: .ended), on: older)
        #expect(controller.model.swipe.swipedRowID == older.id)

        controller.rowDrag(.began)

        #expect(controller.model.swipe.swipedRowID == nil)
    }
}
