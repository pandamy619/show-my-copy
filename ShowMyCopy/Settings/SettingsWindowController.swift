import AppKit
import SwiftUI

/// Shows the settings in a regular window. The app has no Dock or menu bar icon, so it opens the window itself.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let history: any HistoryStore
    private let settings: HistorySettings
    private let passwords: PasswordSettings
    /// Kept across closes, so the breakdown cache and the last memory reading survive a fresh form.
    private let usage: StorageUsage
    private let shortcutRecorder: AnyView
    private var window: NSWindow?

    init<ShortcutRecorder: View>(
        history: any HistoryStore,
        settings: HistorySettings,
        passwords: PasswordSettings,
        memoryReader: any MemoryUsageReading,
        @ViewBuilder shortcutRecorder: () -> ShortcutRecorder
    ) {
        self.history = history
        self.settings = settings
        self.passwords = passwords
        self.usage = StorageUsage(history: history, memoryReader: memoryReader)
        self.shortcutRecorder = AnyView(shortcutRecorder())
        super.init()
    }

    /// Opens the settings window, or brings it to the front if it is already open.
    func show() {
        // The store files can change size without a change to the history. Show their size as it is now.
        usage.refreshDiskBytes()
        let window = self.window ?? makeWindow()
        self.window = window
        // Closing this window hides the app. Show its windows again.
        NSApplication.shared.unhideWithoutActivation()
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
        // An app without a Dock icon keeps being active after its last window closes, so no window has focus.
        // Hiding the app returns focus to the app the user was in before. Not while another window is open.
        let closingWindow = window
        let otherWindowIsVisible = NSApplication.shared.windows.contains { $0 !== closingWindow && $0.isVisible }
        if !otherWindowIsVisible {
            NSApplication.shared.hide(nil)
        }
    }

    private func makeContent() -> NSViewController {
        NSHostingController(
            rootView: SettingsView(history: history, settings: settings, passwords: passwords, usage: usage) {
                shortcutRecorder
            }
        )
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
