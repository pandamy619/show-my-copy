import AppIntents
import AppKit
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private var container: AppContainer?
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
