import AppKit
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private var container: AppContainer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app. Do not open the saved history, read the real clipboard or register the
        // hotkey there.
        guard !Self.isRunningTests else {
            return
        }
        let container = AppContainer(store: Self.makeHistoryStore(), makeSettingsWindow: Self.makeSettingsWindow)
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

    /// The history saved on disk, with passwords encrypted by a key kept in the Keychain.
    ///
    /// Without the key, passwords are kept in memory only and everything else is still saved. When the store on
    /// disk cannot be opened, the history is kept in memory only, as before v2, and `storageError` tells why.
    private static func makeHistoryStore() -> any HistoryStore {
        let sealer: (any SecretSealing)?
        do {
            sealer = try KeychainSecretSealer()
        } catch {
            AppLogger.history.error(
                "No key for saved passwords, keeping them in memory: \(String(describing: error), privacy: .private)")
            sealer = nil
        }
        let opened = SwiftDataHistoryPersistence.openDefault()
        // Loading deletes the entries the limits do not allow, so load with the limit the user saved, not the
        // default one. `AppContainer.start()` applies the same limit again.
        let retention = RetentionPolicy(entryLimit: HistorySettings.storedLimit(in: .standard))
        return PersistentHistoryStore(
            persistence: opened.persistence,
            sealer: sealer,
            retention: retention,
            openError: opened.error
        )
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
