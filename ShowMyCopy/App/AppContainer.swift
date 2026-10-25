import AppKit
import Foundation
import Synchronization

/// Builds the app's objects, connects them and owns them for as long as the app runs: the one place that wires
/// objects together.
///
/// It is given the loaded history and the services that depend on the system or on macOS-only frameworks
/// (`AppServices`); everything else it makes itself, and everything it makes takes protocols. The initializer has no
/// side effects: nothing reads the pasteboard, changes the history or observes notifications until `start()`.
///
/// The operations below are what the app offers to the outside: the global shortcut, reopening the app and, once
/// they are added, App Intents. An intent reaches the container through App Intents dependencies, without a global:
/// the app registers it once at launch with `AppDependencyManager.shared.add { container }`, and the intent declares
/// `@Dependency private var container: AppContainer` and calls `container.toggleHistory()` on the main actor.
/// The intent must run in the app's process, not in a widget extension, because the container lives here.
@MainActor
final class AppContainer {
    let store: any HistoryStore
    let storage: any HistoryStorage
    let settings: AppSettings
    let monitor: ClipboardMonitor
    let activityObserver: SystemActivityObserver
    let copier: EntryCopier
    let historyWindow: HistoryWindowController
    let settingsWindow: any SettingsWindowShowing
    private let sleep: @Sendable (Duration) async throws -> Void

    /// How long quitting waits for the images and thumbnails of copies made just before. Logging out waits for
    /// the app too, so this stays short.
    nonisolated static let quitBudget: Duration = .seconds(2)

    var historySettings: HistorySettings { settings.history }
    var passwordSettings: PasswordSettings { settings.passwords }

    /// `history` is the saved history, loaded with the limits and password choice saved in `defaults`
    /// (`HistorySettings.storedRetention(in:)`, `PasswordSettings.storedSavesPasswords(in:)`).
    init(history: AppHistory, services: AppServices, defaults: UserDefaults) {
        let store = history.store
        let system = services.system
        let media = services.media
        let settings = Self.makeSettings(history: history, services: services, defaults: defaults)
        let settingsWindow = services.makeSettingsWindow(settings)

        // The monitor reads the password setting on every change, so a new choice applies to the next copy.
        let monitor = ClipboardMonitor(
            pasteboard: services.pasteboard,
            history: store,
            schedule: PollingSchedule(sleep: system.sleep, activity: system.pollingActivity),
            expiry: HistoryExpiry(history: store, now: system.now),
            clearedClipboard: ClearedClipboardCheck(history: store),
            capture: Self.makeCapture(store: store, media: media),
            frontmostApp: system.frontmostApp,
            now: system.now,
            passwordPolicy: { [passwords = settings.passwords] in passwords.policy }
        )
        let copier = EntryCopier(
            history: store, pasteboard: services.pasteboard, monitor: monitor, blobs: media.blobs, now: system.now)
        // Rows read thumbnails and the preview reads full images from the same blobs the store keeps.
        let previews = PreviewServices(blobs: media.blobs, images: media.previewImages, richText: media.previewRichText)
        let historyWindow = HistoryWindowController(
            model: HistoryWindowModel(history: store, previews: previews),
            copier: copier,
            monitor: monitor,
            onOpenSettings: { [weak settingsWindow] in
                settingsWindow?.show()
            }
        )

        let activityObserver = SystemActivityObserver(
            monitor: monitor,
            workspace: system.workspaceNotifications,
            distributed: system.distributedNotifications,
            isScreenLocked: system.isScreenLocked,
            isSessionActive: system.isSessionActive
        )
        Self.connect(activityObserver, to: historyWindow, storage: history.storage)

        self.store = store
        self.storage = history.storage
        self.settings = settings
        self.monitor = monitor
        self.activityObserver = activityObserver
        self.copier = copier
        self.historyWindow = historyWindow
        self.settingsWindow = settingsWindow
        self.sleep = system.sleep
    }

    /// Every setting, read from `defaults` and applied to `history`.
    private static func makeSettings(
        history: AppHistory,
        services: AppServices,
        defaults: UserDefaults
    ) -> AppSettings {
        AppSettings(
            store: history.store,
            history: HistorySettings(history: history.store, defaults: defaults, now: services.system.now),
            passwords: PasswordSettings(history: history, defaults: defaults, now: services.system.now),
            storage: StorageUsage(history: history, memoryReader: services.memoryReader)
        )
    }

    private static func connect(
        _ activityObserver: SystemActivityObserver,
        to historyWindow: HistoryWindowController,
        storage: any HistoryStorage
    ) {
        // Close the history when the Mac sleeps, locks or switches users, so it is not on screen for whoever
        // wakes or unlocks it next.
        activityObserver.onUserAway = { [weak historyWindow] in
            historyWindow?.hide()
        }
        // Saved passwords wait while the Keychain is locked: try the key again when the user is back.
        activityObserver.onUserBack = { [weak storage] in
            loadPasswordKey(of: storage)
        }
    }

    /// Images are recorded only with a way to make thumbnails, and copied photo and video files get thumbnails only
    /// with a way to make them; both also need somewhere to keep them.
    private static func makeCapture(store: any HistoryStore, media: AppServices.Media) -> CaptureEnrichment? {
        media.blobs.map { blobs in
            CaptureEnrichment(
                history: store, blobs: blobs, images: media.thumbnails.map { ImageIngestor(thumbnails: $0) },
                fileThumbnails: media.fileThumbnails.map { FileThumbnailIngestor(maker: $0) })
        }
    }

    /// Starts watching the clipboard and the system.
    func start() {
        // The monitor records what is on the pasteboard as soon as it starts. Apply the saved limit first, so the
        // history never holds more entries than the user allowed.
        historySettings.applyStoredLimits()
        // The saved history may still hold passwords from a session in which removing them from disk failed,
        // for example after saving passwords was turned off. Saving them is off now, so they go.
        if !passwordSettings.savesPasswords {
            store.removeConcealed()
        }
        activityObserver.start()
        monitor.start()
        // Saved passwords are opened once their key is loaded, off the main actor: reading the Keychain can wait
        // for the user to answer a prompt, and the launch does not wait for it.
        Self.loadPasswordKey(of: storage)
    }

    /// Loads the key of saved passwords in the background, when passwords wait for it.
    private static func loadPasswordKey(of storage: (any HistoryStorage)?) {
        guard let storage else {
            return
        }
        Task {
            await storage.loadPasswordKey()
        }
    }

    /// Shows the history window, or hides it when it is open. Only a person at the awake, unlocked Mac can ask for
    /// it, so pauses left by a missed wake or unlock notification are cleared before the window catches up with
    /// the pasteboard.
    func toggleHistory() {
        historyWindow.shortcutPressed()
    }

    func showSettings() {
        settingsWindow.show()
    }

    /// Whether the data or thumbnails of a recorded copy are still being saved.
    var isCapturing: Bool {
        monitor.isEnriching
    }

    /// Waits until the images and thumbnails of the copies recorded so far are in the history, so quitting right
    /// after a copy does not lose it, but no longer than `budget`. What is not done by then is lost with the quit.
    func finishCapturing(within budget: Duration) async {
        guard isCapturing else {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finished = FinishOnce { continuation.resume() }
            Task { @MainActor [monitor] in
                await monitor.finishEnriching()
                finished.run()
            }
            Task { [sleep] in
                do {
                    try await sleep(budget)
                } catch {
                    // Cancelled: the app quits anyway.
                }
                finished.run()
            }
        }
    }
}

/// Runs an action once, whichever of several callers comes first.
private final class FinishOnce: Sendable {
    private let action: Mutex<(@Sendable () -> Void)?>

    init(_ action: @escaping @Sendable () -> Void) {
        self.action = Mutex(action)
    }

    func run() {
        let action = action.withLock { action in
            defer { action = nil }
            return action
        }
        action?()
    }
}
