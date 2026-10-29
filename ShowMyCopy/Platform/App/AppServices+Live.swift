import AppKit
import KeyboardShortcuts

extension AppServices {
    /// The services the app runs on: the system pasteboard, clock, notifications and session state, ImageIO and
    /// QuickLook for images and thumbnails, Mach calls for the app's memory, `SMAppService` for opening at login,
    /// and the SwiftUI settings window with the shortcut recorder. This file is the only place that names the macOS
    /// implementations the app runs on.
    @MainActor
    static func live(blobs: InFlightBlobStore?) -> AppServices {
        AppServices(
            pasteboard: SystemPasteboard(),
            system: System(
                now: { Date() },
                frontmostApp: { SourceApp.frontmost() },
                sleep: PollingSchedule.sleepWithTolerance,
                pollingActivity: ProcessPollingActivity(),
                workspaceNotifications: NotificationCenterObserver(center: NSWorkspace.shared.notificationCenter),
                distributedNotifications: DistributedNotificationObserver(),
                isScreenLocked: { ConsoleSession.isScreenLocked() },
                isSessionActive: { ConsoleSession.isActive() }
            ),
            media: Media(
                blobs: blobs,
                thumbnails: ImageIOThumbnailMaker(),
                fileThumbnails: QuickLookFileThumbnailMaker(),
                previewImages: ImageIOPreviewDecoder(),
                previewRichText: AppKitRichTextRenderer()
            ),
            memoryReader: TaskMemoryReader(),
            loginItem: MainAppLoginItem(),
            makeSettingsWindow: { settings in
                SettingsWindowController(settings: settings) {
                    KeyboardShortcuts.Recorder(for: .toggleHistoryWindow)
                }
            }
        )
    }
}

extension InFlightBlobStore {
    /// The folder for image data next to the history, with a running total of its size so Settings never list the
    /// folder after a change. Without it images are not recorded; everything else works.
    @MainActor
    static func openSaved() -> InFlightBlobStore? {
        do {
            return InFlightBlobStore(base: MeasuredBlobStore(base: try FileBlobStore.openDefault()))
        } catch {
            AppLogger.history.error("Images are not recorded: their folder could not be opened")
            return nil
        }
    }
}

extension AppHistory {
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
    @MainActor
    static func loadSaved(blobs: (any BlobStore)?, defaults: UserDefaults) async -> AppHistory {
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
        let store = await PersistentHistoryStore.load(
            persistence: opened.persistence,
            sealer: sealer,
            savesPasswords: PasswordSettings.storedSavesPasswords(in: defaults),
            retention: HistorySettings.storedRetention(in: defaults),
            now: { Date() },
            openError: opened.error,
            blobs: blobs,
            leftovers: opened.leftovers
        )
        return AppHistory(store)
    }
}

extension SettingsWindowController: SettingsWindowShowing {}
