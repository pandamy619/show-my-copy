import AppKit
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private let history = ClipboardHistory()
    private var historySettings: HistorySettings?
    private var monitor: ClipboardMonitor?
    private var activityObserver: SystemActivityObserver?
    private var historyWindow: HistoryWindowController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app. Do not read the real clipboard or register the hotkey there.
        guard !Self.isRunningTests else {
            return
        }
        // Apply the saved limit before the first entry is recorded.
        let historySettings = HistorySettings(history: history)
        let settingsWindow = SettingsWindowController(history: history, settings: historySettings) {
            KeyboardShortcuts.Recorder(for: .toggleHistoryWindow)
        }

        let pasteboard = SystemPasteboard()
        let monitor = ClipboardMonitor(pasteboard: pasteboard, history: history)
        let historyWindow = HistoryWindowController(
            history: history,
            pasteboard: pasteboard,
            monitor: monitor,
            onOpenSettings: { [weak settingsWindow] in
                settingsWindow?.show()
            }
        )
        KeyboardShortcuts.onKeyDown(for: .toggleHistoryWindow) { [weak historyWindow] in
            historyWindow?.shortcutPressed()
        }

        let activityObserver = SystemActivityObserver(monitor: monitor)
        // Close the history when the Mac sleeps, locks or switches users, so it is not on screen for whoever
        // wakes or unlocks it next.
        activityObserver.onUserAway = { [weak historyWindow] in
            historyWindow?.hide()
        }
        activityObserver.start()
        monitor.start()

        self.historySettings = historySettings
        self.settingsWindow = settingsWindow
        self.monitor = monitor
        self.historyWindow = historyWindow
        self.activityObserver = activityObserver

        let firstLaunch = FirstLaunch()
        if firstLaunch.shouldShowSettings {
            settingsWindow.show()
            firstLaunch.settingsWereShown()
        }
    }

    func showSettings() {
        settingsWindow?.show()
    }

    /// The app has no Dock or menu bar icon. Opening it again from Finder, Spotlight or Launchpad shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
}
