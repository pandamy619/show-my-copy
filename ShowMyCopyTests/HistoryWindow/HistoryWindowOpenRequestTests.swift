import Testing

@testable import ShowMyCopy

/// The Control Center button opens the history window and never closes it, unlike the shortcut.
@MainActor
struct HistoryWindowOpenRequestTests {
    private let history = ClipboardHistory()
    private let monitor: ClipboardMonitor

    init() {
        monitor = MonitorFactory.make(pasteboard: FakePasteboard(), history: history)
    }

    private func makeController(monitor: any PasteboardChangeTracking) -> HistoryWindowController {
        HistoryWindowController(
            model: HistoryWindowModel(history: history),
            copier: EntryCopier(history: history, pasteboard: FakePasteboard(), monitor: monitor),
            monitor: monitor,
            onOpenSettings: {}
        )
    }

    @Test func openRequestClearsStalePauseReasonsAndKeepsTheWindowOpen() {
        let controller = makeController(monitor: monitor)
        // The unlock notification was missed, so the monitor still thinks the screen is locked.
        monitor.pause(for: .screenLocked)

        controller.openRequested()
        #expect(monitor.pauseReasons.isEmpty)
        #expect(controller.isVisible)

        // Unlike the shortcut, asking again does not close the window.
        controller.openRequested()
        #expect(controller.isVisible)
    }

    @Test func openRequestClearsPauseReasonsBeforeCatchingUpAndLeavesAnOpenWindowAlone() {
        let tracker = ChangeTrackerSpy()
        let controller = makeController(monitor: tracker)

        controller.openRequested()
        #expect(tracker.calls == [.userIsActive, .poll, .historyWindowOpened(true)])

        // The open window keeps its query and selection: no catch-up, no new presentation.
        controller.openRequested()
        #expect(tracker.calls == [.userIsActive, .poll, .historyWindowOpened(true), .userIsActive])
        #expect(controller.isVisible)
    }
}
