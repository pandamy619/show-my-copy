import AppKit
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private var container: AppContainer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app. Do not read the real clipboard or register the hotkey there.
        guard !Self.isRunningTests else {
            return
        }
        let container = AppContainer(makeSettingsWindow: Self.makeSettingsWindow)
        KeyboardShortcuts.onKeyDown(for: .toggleHistoryWindow) { [weak container] in
            container?.toggleHistory()
        }
        container.start()
        self.container = container

        let firstLaunch = FirstLaunch()
        if firstLaunch.shouldShowSettings {
            container.showSettings()
            firstLaunch.settingsWereShown()
        }
    }

    func showSettings() {
        container?.showSettings()
    }

    /// The app has no Dock or menu bar icon. Opening it again from Finder, Spotlight or Launchpad shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// The settings window shows the shortcut recorder, a SwiftUI view from KeyboardShortcuts, and the app's
    /// memory, read with Mach calls. Both are made here, so `AppContainer` depends on neither.
    private static func makeSettingsWindow(
        history: any HistoryStore,
        settings: HistorySettings,
        passwords: PasswordSettings
    ) -> any SettingsWindowShowing {
        SettingsWindowController(
            history: history,
            settings: settings,
            passwords: passwords,
            memoryReader: TaskMemoryReader()
        ) {
            KeyboardShortcuts.Recorder(for: .toggleHistoryWindow)
        }
    }
}

extension SettingsWindowController: SettingsWindowShowing {}
