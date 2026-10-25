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
        let firstLaunch = FirstLaunch()
        // Before anything opens the history: development builds saved it in a format that is gone.
        if let applicationSupport = HistoryFolder.applicationSupport() {
            LegacyHistoryFiles(appFolder: HistoryFolder.appFolder(inApplicationSupport: applicationSupport)).delete()
        }
        // One store for the history and the work that saves images in the background, so neither deletes what the
        // other is about to use.
        // Settings show their size from a running total, so nothing lists the folder after every change.
        let blobs = Self.openBlobStore().map { InFlightBlobStore(base: MeasuredBlobStore(base: $0)) }
        // The saved history is decoded in the background; the app starts watching the clipboard once it is loaded.
        Task {
            let store = await Self.loadHistoryStore(blobs: blobs)
            finishLaunching(store: store, blobs: blobs, firstLaunch: firstLaunch)
        }
    }

    private func finishLaunching(store: PersistentHistoryStore, blobs: InFlightBlobStore?, firstLaunch: FirstLaunch) {
        let container = AppContainer(
            history: AppHistory(store),
            blobs: blobs,
            thumbnails: ImageIOThumbnailMaker(),
            fileThumbnails: QuickLookFileThumbnailMaker(),
            previewImages: ImageIOPreviewDecoder(),
            previewRichText: AppKitRichTextRenderer(),
            makeSettingsWindow: Self.makeSettingsWindow
        )
        KeyboardShortcuts.onKeyDown(for: .toggleHistoryWindow) { [weak container] in
            container?.toggleHistory()
        }
        container.start()
        self.container = container

        if firstLaunch.shouldShowSettings {
            container.showSettings()
            firstLaunch.settingsWereShown()
        }
    }

    func showSettings() {
        container?.showSettings()
    }

    /// Images and thumbnails of copies made just before quitting or logging out are still being saved: let them
    /// reach the history first, for at most `AppContainer.quitBudget`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let container, container.isCapturing else {
            return .terminateNow
        }
        Task {
            await container.finishCapturing(within: AppContainer.quitBudget)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The app has no Dock or menu bar icon. Opening it again from Finder, Spotlight or Launchpad shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// The folder for image data next to the history. Without it images are not recorded; everything else works.
    private static func openBlobStore() -> FileBlobStore? {
        do {
            return try FileBlobStore.openDefault()
        } catch {
            AppLogger.history.error("Images are not recorded: their folder could not be opened")
            return nil
        }
    }

    /// The history saved on disk, with passwords encrypted by a key kept in the Keychain.
    ///
    /// The key is read or created only when a password is saved or a saved one is loaded: getting it can show a
    /// Keychain prompt, which users who never save passwords should not see. It is read off the main thread
    /// (`LazySecretSealer`, `PersistentHistoryStore.loadPasswordKey()`), so the launch never waits for that prompt;
    /// saved passwords wait on disk until it is read. Saved passwords that have expired, or all of them when saving
    /// passwords is off, are deleted at load without the key. Without the key, passwords copied now are kept in
    /// memory only, saved ones stay on disk for the next try, and everything else is still saved. When the store on
    /// disk cannot be opened, the history is kept in memory only and `storageError` tells why. Image data is in
    /// `blobs`; the store deletes it with its entries and sweeps what no entry uses at launch.
    private static func loadHistoryStore(blobs: (any BlobStore)?) async -> PersistentHistoryStore {
        let sealer = LazySecretSealer { () throws(SecretSealingError) -> any SecretSealing in
            do throws(SecretSealingError) {
                return try KeychainSecretSealer()
            } catch {
                AppLogger.history.error(
                    "No key for saved passwords; they stay in memory: \(String(describing: error), privacy: .private)")
                throw error
            }
        }
        let opened = SwiftDataHistoryPersistence.openDefault()
        // Loading deletes the entries the limits do not allow, and saved passwords when saving them is off, so
        // load with the limits and the password choice the user saved, not the defaults. `AppContainer.start()`
        // applies the same limits and removes passwords again.
        return await PersistentHistoryStore.load(
            persistence: opened.persistence,
            sealer: sealer,
            savesPasswords: PasswordSettings.storedSavesPasswords(in: .standard),
            retention: HistorySettings.storedRetention(in: .standard),
            now: { Date() },
            openError: opened.error,
            blobs: blobs,
            leftovers: opened.leftovers
        )
    }

    /// The settings window shows the shortcut recorder, a SwiftUI view from KeyboardShortcuts, and the app's
    /// memory, read with Mach calls. Both are made here, so `AppContainer` depends on neither.
    private static func makeSettingsWindow(
        history: AppHistory,
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
