import AppKit
import Foundation

/// Builds the app's objects, connects them and owns them for as long as the app runs.
///
/// This is the one place that picks the concrete types: where the history lives, which pasteboard is read and
/// which notification centers are observed. Everything else takes protocols. The initializer has no side effects:
/// nothing reads the pasteboard, changes the history or observes notifications until `start()`.
///
/// The operations below are what the app offers to the outside: the global shortcut, reopening the app and, once
/// they are added, App Intents. An intent reaches the container through App Intents dependencies, without a global:
/// the app registers it once at launch with `AppDependencyManager.shared.add { container }`, and the intent declares
/// `@Dependency private var container: AppContainer` and calls `container.toggleHistory()` on the main actor.
/// The intent must run in the app's process, not in a widget extension, because the container lives here.
@MainActor
final class AppContainer {
    /// Makes the settings window from the objects it shows. The real window is built with SwiftUI and includes
    /// the shortcut recorder, so `AppDelegate` passes this in.
    typealias SettingsWindowFactory =
        @MainActor (
            _ history: any HistoryStore,
            _ settings: HistorySettings,
            _ passwords: PasswordSettings
        ) -> any SettingsWindowShowing

    let store: any HistoryStore
    let historySettings: HistorySettings
    let passwordSettings: PasswordSettings
    let pasteboard: any PasteboardReading & PasteboardWriting
    /// Where image data and thumbnails are kept, or nil when images are not recorded. History rows read thumbnails
    /// from it; the full image is read only when it is opened or copied.
    let blobs: (any BlobStore)?
    let monitor: ClipboardMonitor
    let activityObserver: SystemActivityObserver
    let copier: EntryCopier
    let historyWindow: HistoryWindowController
    let settingsWindow: any SettingsWindowShowing

    /// The defaults are the real system services. Tests pass fakes.
    init(
        store: any HistoryStore = InMemoryHistoryStore(),
        pasteboard: any PasteboardReading & PasteboardWriting = SystemPasteboard(),
        defaults: UserDefaults = .standard,
        now: @escaping @MainActor () -> Date = { Date() },
        frontmostApp: @escaping @MainActor () -> SourceApp? = { SourceApp.frontmost() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        pollingActivity: any PollingActivity = ProcessPollingActivity(),
        workspaceNotifications: any NotificationObserving = NotificationCenterObserver(
            center: NSWorkspace.shared.notificationCenter
        ),
        distributedNotifications: any NotificationObserving = DistributedNotificationObserver(),
        isScreenLocked: @escaping @MainActor () -> Bool = { ConsoleSession.isScreenLocked() },
        isSessionActive: @escaping @MainActor () -> Bool = { ConsoleSession.isActive() },
        blobs: (any BlobStore)? = nil,
        thumbnails: (any ThumbnailMaking)? = nil,
        fileThumbnails: (any FileThumbnailMaking)? = nil,
        previewImages: (any PreviewImageDecoding)? = nil,
        previewRichText: (any RichTextRendering)? = nil,
        makeSettingsWindow: SettingsWindowFactory
    ) {
        let historySettings = HistorySettings(history: store, defaults: defaults)
        let passwordSettings = PasswordSettings(history: store, defaults: defaults, now: now)
        let settingsWindow = makeSettingsWindow(store, historySettings, passwordSettings)

        let ingestors = Self.makeIngestors(blobs: blobs, thumbnails: thumbnails, fileThumbnails: fileThumbnails)
        // The monitor reads the password setting on every change, so a new choice applies to the next copy.
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            history: store,
            schedule: PollingSchedule(sleep: sleep, activity: pollingActivity),
            expiry: PasswordExpiry(history: store, now: now),
            frontmostApp: frontmostApp,
            now: now,
            passwordPolicy: { [passwordSettings] in passwordSettings.policy },
            imageIngestor: ingestors.images,
            fileThumbnailIngestor: ingestors.files
        )
        let copier = EntryCopier(history: store, pasteboard: pasteboard, monitor: monitor, blobs: blobs, now: now)
        // Rows read thumbnails and the preview reads full images from the same blobs the store keeps.
        let previews = PreviewServices(blobs: blobs, images: previewImages, richText: previewRichText)
        let historyWindow = HistoryWindowController(
            history: store,
            model: HistoryWindowModel(history: store, previews: previews),
            copier: copier,
            monitor: monitor,
            onOpenSettings: { [weak settingsWindow] in
                settingsWindow?.show()
            }
        )

        let activityObserver = SystemActivityObserver(
            monitor: monitor,
            workspace: workspaceNotifications,
            distributed: distributedNotifications,
            isScreenLocked: isScreenLocked,
            isSessionActive: isSessionActive
        )
        // Close the history when the Mac sleeps, locks or switches users, so it is not on screen for whoever
        // wakes or unlocks it next.
        activityObserver.onUserAway = { [weak historyWindow] in
            historyWindow?.hide()
        }

        self.store = store
        self.historySettings = historySettings
        self.passwordSettings = passwordSettings
        self.pasteboard = pasteboard
        self.blobs = blobs
        self.monitor = monitor
        self.activityObserver = activityObserver
        self.copier = copier
        self.historyWindow = historyWindow
        self.settingsWindow = settingsWindow
    }

    /// Images are recorded only with somewhere to keep them and a way to make thumbnails, and copied photo and video
    /// files get thumbnails only with somewhere to keep them. The store must delete blobs in the same `blobs`.
    private static func makeIngestors(
        blobs: (any BlobStore)?,
        thumbnails: (any ThumbnailMaking)?,
        fileThumbnails: (any FileThumbnailMaking)?
    ) -> (images: ImageIngestor?, files: FileThumbnailIngestor?) {
        guard let blobs else {
            return (nil, nil)
        }
        return (
            thumbnails.map { ImageIngestor(blobs: blobs, thumbnails: $0) },
            fileThumbnails.map { FileThumbnailIngestor(blobs: blobs, maker: $0) }
        )
    }

    /// Starts watching the clipboard and the system.
    func start() {
        // The monitor records what is on the pasteboard as soon as it starts. Apply the saved limit first, so the
        // history never holds more entries than the user allowed.
        historySettings.applyStoredLimit()
        // The saved history may still hold passwords from a session in which removing them from disk failed,
        // for example after saving passwords was turned off. Saving them is off now, so they go.
        if !passwordSettings.savesPasswords {
            store.removeConcealed()
        }
        activityObserver.start()
        monitor.start()
    }

    /// Shows the history window, or hides it when it is open. Only a person at the awake, unlocked Mac can ask for
    /// it, so pauses left by a missed wake or unlock notification are cleared before the window catches up with
    /// the pasteboard.
    func toggleHistory() {
        historyWindow.shortcutPressed()
    }

    func hideHistory() {
        historyWindow.hide()
    }

    func showSettings() {
        settingsWindow.show()
    }
}
