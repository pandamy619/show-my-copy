import AppKit
import Foundation
import Synchronization

/// Builds the app's objects, connects them and owns them for as long as the app runs: the one place that wires
/// objects together.
///
/// It is given the loaded history and the services that depend on the system and its frameworks
/// (`AppServices`); everything else it makes itself, and everything it makes takes protocols. The initializer has no
/// side effects: nothing reads the pasteboard, changes the history or observes notifications until `start()`.
///
/// The operations below are what the app offers to the outside: the global shortcut, reopening the app and the
/// Control Center button. The button's intent (`OpenHistoryIntent`) reaches the container without a global: it is
/// also built into the Control Center extension, where the container does not exist, so it depends on
/// `HistoryRequests`, which the app registers with App Intents at launch and connects to the container once the
/// container is made. The intent runs only in the app's process, because the container lives here.
@MainActor
final class AppContainer: HistoryShowing {
    let store: any HistoryStore
    let storage: any HistoryStorage
    let settings: AppSettings
    let monitor: ClipboardMonitor
    let activityObserver: SystemActivityObserver
    let copier: EntryCopier
    /// The accounts whose one-time codes the history window lists.
    let codes: CodeAccountStore
    let historyWindow: HistoryWindowController
    let settingsWindow: any SettingsWindowShowing
    private let sleep: @Sendable (Duration) async throws -> Void

    /// How long quitting waits for the images and thumbnails of copies made just before. Logging out waits for
    /// the app too, so this stays short.
    nonisolated static let quitBudget: Duration = .seconds(2)

    /// `history` is the saved history, loaded with the limits and password choice saved in `defaults`
    /// (`HistorySettings.storedRetention(in:)`, `PasswordSettings.storedSavesPasswords(in:)`).
    init(history: AppHistory, services: AppServices, defaults: UserDefaults) {
        let store = history.store
        let system = services.system
        let media = services.media
        // Empties the pasteboard of a password that leaves the history through expiry or the password setting.
        let pasteboardClearer = PasswordPasteboardClearer(history: store, pasteboard: services.pasteboard)
        let (passwords, excludedApps) = Self.makeCaptureSettings(
            history: history, services: services, defaults: defaults, pasteboardClearer: pasteboardClearer)

        let monitor = Self.makeMonitor(
            store: store, services: services, pasteboardClearer: pasteboardClearer, passwords: passwords,
            excludedApps: excludedApps)
        let codes = Self.makeCodes(store: store, services: services, monitor: monitor)
        let settings = Self.makeSettings(
            history: history, services: services, defaults: defaults,
            shared: SharedSettings(passwords: passwords, excludedApps: excludedApps, codes: codes.settings))
        let copier = EntryCopier(
            history: store, pasteboard: services.pasteboard, monitor: monitor, blobs: media.blobs, now: system.now)
        // Text selected in Settings, such as the address in About, is copied like a folder from the history window's
        // preview: without becoming an entry.
        let settingsWindow = services.makeSettingsWindow(settings) { [copier] in copier.copyText($0) }
        // The deleter holds a deleted entry's blobs in the store the history deletes them in, so Undo can bring them
        // back.
        let deleter = EntryDeleter(
            history: store, pasteboard: services.pasteboard, monitor: monitor, blobs: media.blobs, now: system.now)
        let historyWindow = HistoryWindowController(
            model: Self.makeHistoryModel(
                store: store, deleter: deleter, media: media, codes: codes.store, paste: settings.paste),
            copier: copier,
            codeCopier: codes.copier,
            paster: Self.makePaster(services: services, settings: settings.paste),
            monitor: monitor,
            onOpenSettings: { [weak settingsWindow] section in
                settingsWindow?.show(section: section)
            }
        )

        let activityObserver = Self.makeActivityObserver(
            system: system, monitor: monitor, historyWindow: historyWindow, storage: history.storage,
            codes: codes.store)

        self.store = store
        self.storage = history.storage
        self.settings = settings
        self.monitor = monitor
        self.activityObserver = activityObserver
        self.copier = copier
        self.codes = codes.store
        self.historyWindow = historyWindow
        self.settingsWindow = settingsWindow
        self.sleep = system.sleep
    }

    /// The clipboard monitor. It reads the password setting and the excluded apps on every change, so a new choice
    /// applies to the next copy.
    private static func makeMonitor(
        store: any HistoryStore,
        services: AppServices,
        pasteboardClearer: PasswordPasteboardClearer,
        passwords: PasswordSettings,
        excludedApps: ExcludedApps
    ) -> ClipboardMonitor {
        let system = services.system
        let monitor = ClipboardMonitor(
            pasteboard: services.pasteboard,
            history: store,
            schedule: PollingSchedule(sleep: system.sleep, activity: system.pollingActivity),
            expiry: HistoryExpiry(history: store, pasteboardClearer: pasteboardClearer, now: system.now),
            clearedClipboard: ClearedClipboardCheck(history: store),
            capture: Self.makeCapture(store: store, media: services.media),
            frontmostApp: system.frontmostApp,
            now: system.now,
            passwordPolicy: { passwords.policy },
            isExcluded: { excludedApps.excludes(bundleIdentifier: $0) }
        )
        // Only the monitor knows which pasteboard change a password was recorded at.
        pasteboardClearer.connect(to: monitor)
        return monitor
    }

    /// The settings made before the rest: the monitor reads the first two, and the codes come with the monitor.
    private struct SharedSettings {
        let passwords: PasswordSettings
        let excludedApps: ExcludedApps
        let codes: CodesSettings
    }

    /// The settings the clipboard monitor reads on every copy: the password choice and the excluded apps. Made
    /// before the monitor, which the other settings come after.
    private static func makeCaptureSettings(
        history: AppHistory,
        services: AppServices,
        defaults: UserDefaults,
        pasteboardClearer: PasswordPasteboardClearer
    ) -> (PasswordSettings, ExcludedApps) {
        let passwords = PasswordSettings(
            history: history, defaults: defaults, now: services.system.now, pasteboardClearer: pasteboardClearer)
        let excludedApps = ExcludedApps(
            defaults: defaults,
            running: services.system.runningApps,
            chooser: services.system.appChooser,
            ownBundleIdentifier: Bundle.main.bundleIdentifier
        )
        return (passwords, excludedApps)
    }

    /// Every setting, read from `defaults` and applied to `history`, with those made before (`shared`).
    private static func makeSettings(
        history: AppHistory,
        services: AppServices,
        defaults: UserDefaults,
        shared: SharedSettings
    ) -> AppSettings {
        AppSettings(
            store: history.store,
            history: HistorySettings(history: history.store, defaults: defaults, now: services.system.now),
            passwords: shared.passwords,
            storage: StorageUsage(history: history, memoryReader: services.memoryReader),
            launchAtLogin: LaunchAtLoginSettings(service: services.loginItem),
            excludedApps: shared.excludedApps,
            paste: PasteSettings(
                defaults: defaults,
                accessChecker: services.paste.access,
                accessibilitySettings: services.paste.systemSettings
            ),
            codes: shared.codes
        )
    }

    /// The history window's state. Return reads the paste setting each time it is pressed.
    private static func makeHistoryModel(
        store: any HistoryStore,
        deleter: EntryDeleter,
        media: AppServices.Media,
        codes: CodeAccountStore,
        paste: PasteSettings
    ) -> HistoryWindowModel {
        // Rows read thumbnails and the preview reads full images from the same blobs the store keeps.
        let previews = PreviewServices(blobs: media.blobs, images: media.previewImages, richText: media.previewRichText)
        return HistoryWindowModel(
            history: store, deleter: deleter, previews: previews, codes: codes, pastesAfterChoosing: { paste.isOn })
    }

    /// Pastes into the app in front, never into this one.
    private static func makePaster(services: AppServices, settings: PasteSettings) -> EntryPaster {
        EntryPaster(
            pasteboard: services.pasteboard,
            keystrokes: services.paste.keystrokes,
            settings: settings,
            frontmostApp: services.system.frontmostApp,
            ownBundleIdentifier: Bundle.main.bundleIdentifier,
            sleep: services.paste.sleep,
            tuning: services.paste.tuning
        )
    }

    /// Watches sleep, the lock screen and user switches, and connects what happens then to the window and the
    /// saved secrets.
    private static func makeActivityObserver(
        system: AppServices.System,
        monitor: ClipboardMonitor,
        historyWindow: HistoryWindowController,
        storage: any HistoryStorage,
        codes: CodeAccountStore
    ) -> SystemActivityObserver {
        let activityObserver = SystemActivityObserver(
            monitor: monitor,
            workspace: system.workspaceNotifications,
            distributed: system.distributedNotifications,
            isScreenLocked: system.isScreenLocked,
            isSessionActive: system.isSessionActive
        )
        // Close the history when the Mac sleeps, locks or switches users, so it is not on screen for whoever
        // wakes or unlocks it next.
        activityObserver.onUserAway = { [weak historyWindow] in
            historyWindow?.hide()
        }
        // Saved passwords and code accounts wait while the Keychain is locked: try the key again when the user is
        // back.
        activityObserver.onUserBack = { [weak storage, weak codes] in
            loadPasswordKey(of: storage)
            loadCodes(codes)
        }
        return activityObserver
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
        settings.history.applyStoredLimits()
        // The saved history may still hold passwords from a session in which removing them from disk failed,
        // for example after saving passwords was turned off. Saving them is off now, so they go.
        if !settings.passwords.savesPasswords {
            store.removeConcealed()
        }
        activityObserver.start()
        monitor.start()
        // Saved passwords are opened once their key is loaded, off the main actor: reading the Keychain can wait
        // for the user to answer a prompt, and the launch does not wait for it. The same for code accounts.
        Self.loadPasswordKey(of: storage)
        Self.loadCodes(codes)
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

    /// Shows the history window, or leaves it open: the Control Center button opens the history and never closes it.
    func showHistory() {
        historyWindow.openRequested()
    }

    /// Brings Settings to the front on the page they show: General, unless the user picked another one while they
    /// were open.
    func showSettings() {
        settingsWindow.show(section: nil)
    }

    /// Shows Settings on the first launch, offering once to open the app at login. The app never turns that on
    /// by itself.
    func showSettingsOnFirstLaunch() {
        settings.launchAtLogin.suggestOnce()
        settingsWindow.show(section: SettingsSection.initial)
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
