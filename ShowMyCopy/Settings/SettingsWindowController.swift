import AppKit
import SwiftUI

/// Shows the settings in a regular window. The app has no Dock or menu bar icon, so it opens the window itself.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let history: ClipboardHistory
    private let settings: HistorySettings
    private let shortcutRecorder: AnyView
    private var window: NSWindow?

    init<ShortcutRecorder: View>(
        history: ClipboardHistory,
        settings: HistorySettings,
        @ViewBuilder shortcutRecorder: () -> ShortcutRecorder
    ) {
        self.history = history
        self.settings = settings
        self.shortcutRecorder = AnyView(shortcutRecorder())
        super.init()
    }

    /// Opens the settings window, or brings it to the front if it is already open.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // The app is LSUIElement, so it is usually not active. Activate it so the window can take focus.
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        // Activation is cooperative since macOS 14 and can be declined. Show the window in front anyway.
        window.orderFrontRegardless()
    }

    /// The window is only hidden when closed. Start from a fresh form next time, without unfinished
    /// edits or an open confirmation.
    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = makeContent()
    }

    private func makeContent() -> NSViewController {
        NSHostingController(rootView: SettingsView(history: history, settings: settings) { shortcutRecorder })
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: makeContent())
        window.title = String(localized: "Show My Copy Settings")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        return window
    }
}
