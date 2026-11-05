import AppIntents
import AppKit
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private var container: AppContainer?
    /// What other copies of the app ask this one, once it knows it is the copy that runs.
    private var runningCopySignals: RunningCopySignals?
    /// How the Control Center button reaches the container, which is made only once the history has loaded.
    private let historyRequests = HistoryRequests()

    /// Before launching finishes: the Control Center button can launch the app, and its intent needs the requests
    /// registered by the time the system performs it.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else {
            return
        }
        // The intent exists only on macOS 26 and later.
        if #available(macOS 26, *) {
            let requests = historyRequests
            AppDependencyManager.shared.add(dependency: requests)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app. Do not open the saved history, read the real clipboard or register the
        // hotkey there.
        guard !Self.isRunningTests else {
            return
        }
        // Before anything reads the clipboard or opens the history: two processes on one saved history would each
        // save every copy, and the next launch would list it twice.
        let duplicateLaunch = DuplicateLaunch(
            anotherIsRunning: { Self.anotherInstanceIsRunning() },
            signals: DistributedInstanceSignals(),
            sleep: { duration in
                try await Task.sleep(for: duration)
            },
            replacement: Self.debugBuildReplacement
        )
        Task {
            guard await duplicateLaunch.resolve() == .keepRunning else {
                NSApplication.shared.terminate(nil)
                return
            }
            listenToOtherCopies()
            launch()
        }
    }

    #if DEBUG
        /// Debug builds only: a newer Debug build, such as the next run from Xcode at another place, asks this one to
        /// quit and takes over. The name is not in Release builds, so they neither post nor observe it and no app
        /// can quit them; `make security` fails if the Release app contains it (`DEBUG_ONLY_STRINGS`).
        private static let debugBuildReplacement: DebugBuildReplacement? = DebugBuildReplacement(
            quitRequest: Notification.Name("com.pandamy619.ShowMyCopy.debug.quitForNewerDebugBuild"))
    #else
        private static let debugBuildReplacement: DebugBuildReplacement? = nil
    #endif

    private func listenToOtherCopies() {
        let signals = RunningCopySignals(notifications: DistributedNotificationObserver(), now: { .now })
        signals.listen(
            showSettings: { [weak self] in
                self?.showSettings()
            },
            replacement: Self.debugBuildReplacement,
            quit: {
                NSApplication.shared.terminate(nil)
            }
        )
        runningCopySignals = signals
    }

    private func launch() {
        let firstLaunch = FirstLaunch()
        // Before anything opens the history: development builds saved it in a format that is gone.
        if let applicationSupport = HistoryFolder.applicationSupport() {
            LegacyHistoryFiles(appFolder: HistoryFolder.appFolder(inApplicationSupport: applicationSupport)).delete()
        }
        // One store for the history and the work that saves images in the background, so neither deletes what the
        // other is about to use.
        let blobs = InFlightBlobStore.openSaved()
        // The saved history is decoded in the background; the app starts watching the clipboard once it is loaded.
        Task {
            let history = await AppHistory.loadSaved(blobs: blobs, defaults: .standard)
            finishLaunching(history: history, blobs: blobs, firstLaunch: firstLaunch)
        }
    }

    /// Asks LaunchServices, which keeps the list of running apps in memory, so nothing waits for the disk.
    private static func anotherInstanceIsRunning() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map { app in
            SingleInstance.RunningCopy(
                bundleIdentifier: app.bundleIdentifier, processIdentifier: app.processIdentifier,
                isTerminated: app.isTerminated)
        }
        return SingleInstance.anotherIsRunning(
            bundleIdentifier: bundleIdentifier, ownProcess: NSRunningApplication.current.processIdentifier,
            running: running)
    }

    private func finishLaunching(history: AppHistory, blobs: InFlightBlobStore?, firstLaunch: FirstLaunch) {
        let container = AppContainer(history: history, services: .live(blobs: blobs), defaults: .standard)
        KeyboardShortcuts.onKeyDown(for: .toggleHistoryWindow) { [weak container] in
            container?.toggleHistory()
        }
        container.start()
        self.container = container
        historyRequests.connect(container)

        if firstLaunch.shouldShowSettings {
            container.showSettingsOnFirstLaunch()
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
}
