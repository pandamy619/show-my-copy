import AppKit
import SwiftUI

/// Shows the settings in a regular window. The app has no Dock or menu bar icon, so it opens the window itself.
///
/// The window has a sidebar of pages (`SettingsView`) and a fixed size; its title bar is transparent and its title
/// hidden, so the sidebar runs up to the top edge.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private let shortcutRecorder: AnyView
    /// Copies text selected in Settings without recording it (`EntryCopying.copyText(_:)`).
    private let copyText: @MainActor (String) -> Void
    /// The page shown. Kept while the app runs, so a caller can pick a page while the window is open.
    private let navigation = SettingsNavigation()
    private var window: NSWindow?

    init<ShortcutRecorder: View>(
        settings: AppSettings,
        copyText: @escaping @MainActor (String) -> Void,
        @ViewBuilder shortcutRecorder: () -> ShortcutRecorder
    ) {
        self.settings = settings
        self.copyText = copyText
        self.shortcutRecorder = AnyView(shortcutRecorder())
        super.init()
    }

    /// Opens the settings window on `section`, or brings it to the front if it is already open. With nil it keeps
    /// the page it shows.
    func show(section: SettingsSection?) {
        // The store files can change size without a change to the history. Show their size as it is now, and count
        // the saved images again, in the background.
        Task { [usage = settings.storage] in
            await usage.refreshDiskBytes(recountingImages: true)
        }
        // The user can change opening at login in System Settings at any time: ask macOS again.
        Task { [launchAtLogin = settings.launchAtLogin] in
            await launchAtLogin.settingsOpened()
        }
        // The same for permission to paste, which the user can take back in Privacy & Security at any time.
        settings.paste.refresh()
        navigation.show(section)
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

    /// The window is only hidden when closed. Start from a fresh form on the first page next time, without
    /// unfinished edits or an open confirmation.
    func windowWillClose(_ notification: Notification) {
        navigation.windowClosed()
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

    /// Also when the user comes back from System Settings → Login Items or Privacy & Security: the app has no Dock
    /// icon and is not in the app switcher, so they return by clicking this window. Read whether the app opens at
    /// login and may paste again.
    func windowDidBecomeKey(_ notification: Notification) {
        Task { [launchAtLogin = settings.launchAtLogin] in
            await launchAtLogin.refresh()
        }
        settings.paste.refresh()
    }

    /// The window takes the size the content asks for (`SettingsView`), also when the content is replaced on close.
    private func makeContent() -> NSViewController {
        let controller = NSHostingController(
            rootView: SettingsView(settings: settings, navigation: navigation, copyText: copyText) {
                shortcutRecorder
            }
        )
        controller.sizingOptions = [.preferredContentSize]
        return controller
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: makeContent())
        // Hidden in the title bar, but still the window's name in Mission Control and for VoiceOver.
        window.title = String(localized: "Show My Copy Settings")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        return window
    }
}
