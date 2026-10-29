import AppKit
import SwiftUI

/// Shows the settings in a regular window. The app has no Dock or menu bar icon, so it opens the window itself.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private let shortcutRecorder: AnyView
    private var window: NSWindow?

    init<ShortcutRecorder: View>(
        settings: AppSettings,
        @ViewBuilder shortcutRecorder: () -> ShortcutRecorder
    ) {
        self.settings = settings
        self.shortcutRecorder = AnyView(shortcutRecorder())
        super.init()
    }

    /// Opens the settings window, or brings it to the front if it is already open.
    func show() {
        // The store files can change size without a change to the history. Show their size as it is now, and count
        // the saved images again, in the background.
        Task { [usage = settings.storage] in
            await usage.refreshDiskBytes(recountingImages: true)
        }
        // The user can change opening at login in System Settings at any time: ask macOS again.
        Task { [launchAtLogin = settings.launchAtLogin] in
            await launchAtLogin.settingsOpened()
        }
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
        settings.launchAtLogin.settingsClosed()
        // An app without a Dock icon keeps being active after its last window closes, so no window has focus.
        // Hiding the app returns focus to the app the user was in before. Not while another window is open.
        let closingWindow = window
        let otherWindowIsVisible = NSApplication.shared.windows.contains { $0 !== closingWindow && $0.isVisible }
        if !otherWindowIsVisible {
            NSApplication.shared.hide(nil)
        }
    }

    /// Also when the user comes back from System Settings → Login Items: the app has no Dock icon and is not in the
    /// app switcher, so they return by clicking this window. Read whether the app opens at login again.
    func windowDidBecomeKey(_ notification: Notification) {
        Task { [launchAtLogin = settings.launchAtLogin] in
            await launchAtLogin.refresh()
        }
    }

    private func makeContent() -> NSViewController {
        NSHostingController(
            rootView: SettingsView(settings: settings) {
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
