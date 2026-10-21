import AppKit
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

    @Test func choosingAnEntryCopiesItAndCloses() throws {
        pasteboard.copy("older")
        monitor.poll()
        pasteboard.copy("newer")
        let controller = makeController()
        controller.show()
        let older = try #require(controller.model.items.last)

        controller.choose(older)

        #expect(pasteboard.writtenTexts == ["older"])
        #expect(!controller.isVisible)
    }

    @Test func failedCopyKeepsTheWindowOpen() throws {
        pasteboard.copy("older")
        monitor.poll()
        pasteboard.copy("newer")
        let controller = makeController()
        controller.show()
        let older = try #require(controller.model.items.last)
        pasteboard.writeFails = true

        controller.choose(older)

        // Nothing was copied, so the user can try again.
        #expect(controller.isVisible)
        #expect(pasteboard.string() == "newer")

        pasteboard.writeFails = false
        controller.choose(older)
        #expect(pasteboard.writtenTexts == ["older"])
        #expect(!controller.isVisible)
    }

    @Test func shortcutClearsStalePauseReasonsAndTogglesTheWindow() {
        let controller = makeController()
        // The unlock notification was missed, so the monitor still thinks the screen is locked.
        monitor.pause(for: .screenLocked)

        controller.shortcutPressed()
        #expect(monitor.pauseReasons.isEmpty)
        #expect(controller.isVisible)

        controller.shortcutPressed()
        #expect(!controller.isVisible)
    }

    @Test func closingTheWindowHidesRevealedPasswords() throws {
        pasteboard.copy("older")
        monitor.poll()
        history.record(text: "hunter2", sourceApp: nil, at: Date(), concealed: true, expiresAt: .distantFuture)
        let controller = makeController()
        controller.show()
        let password = try #require(controller.model.items.first)
        controller.model.toggleReveal(password.id)

        controller.hide()
        #expect(!controller.model.isRevealed(password.id))
    }

    @Test func showRemovesExpiredPasswords() {
        let environment = MonitorEnvironment()
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        pasteboard.copy("older")
        monitor.poll()
        history.record(
            text: "hunter2", sourceApp: nil, at: environment.now, concealed: true, expiresAt: environment.now + 60)
        let controller = HistoryWindowController(
            history: history, pasteboard: pasteboard, monitor: monitor, onOpenSettings: {})

        environment.now += 60
        controller.show()
        #expect(controller.model.items.map(\.text) == ["older"])
    }

    @Test func showUnhidesTheApp() {
        // Closing Settings hides the app to give focus back to the previous app. A hidden app shows no windows.
        NSApplication.shared.hide(nil)

        makeController().show()

        #expect(!NSApplication.shared.isHidden)
    }
}
