import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct HistoryWindowControllerTests {
    private let pasteboard = FakePasteboard()
    private let history = ClipboardHistory()
    private let monitor: ClipboardMonitor
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    init() {
        monitor = ClipboardMonitor(pasteboard: pasteboard, history: history, frontmostApp: { nil })
    }

    private func makeController() -> HistoryWindowController {
        HistoryWindowController(history: history, pasteboard: pasteboard, monitor: monitor, onOpenSettings: {})
    }

    @Test func showListsACopyMadeSinceTheLastPoll() throws {
        pasteboard.copy("older")
        monitor.poll()
        let controller = makeController()

        // Copied and the shortcut pressed before the next poll.
        pasteboard.copy("just copied")
        controller.show()

        #expect(controller.isVisible)
        #expect(controller.model.items.map(\.text) == ["just copied", "older"])
        let selected = try #require(controller.model.selectedEntry)
        #expect(selected.text == "just copied")
        #expect(controller.model.currentEntryID == selected.id)
    }
}
