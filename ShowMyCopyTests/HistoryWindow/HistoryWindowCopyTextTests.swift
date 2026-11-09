import Foundation
import Testing

@testable import ShowMyCopy

/// Text the user selects in the history window and copies by hand, such as a file's folder in the preview.
@MainActor
@Suite(.serialized, .oneWindowAtATime)
struct HistoryWindowCopyTextTests {
    private let pasteboard = FakePasteboard()
    private let history = InMemoryHistoryStore()
    private let monitor: ClipboardMonitor

    init() {
        monitor = MonitorFactory.make(pasteboard: pasteboard, history: history)
    }

    private func makeController() -> HistoryWindowController {
        HistoryWindowController(
            model: HistoryWindowModel(history: history),
            copier: EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor),
            paster: EntryPasterSpy(),
            monitor: monitor,
            onOpenSettings: { _ in }
        )
    }

    @Test func copyingSelectedTextKeepsTheWindowOpenAndRecordsNothing() throws {
        pasteboard.copy("older")
        monitor.poll()
        let controller = makeController()
        controller.show()

        controller.copySelectedText("~/Documents")
        monitor.poll()

        #expect(pasteboard.writtenTexts == ["~/Documents"])
        #expect(controller.isVisible)
        #expect(controller.model.items.map(\.text) == ["older"])
        #expect(controller.model.currentEntryID == nil)
        controller.hide()
    }
}
