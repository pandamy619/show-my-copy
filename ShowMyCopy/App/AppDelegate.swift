import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private let history = ClipboardHistory()
    private var monitor: ClipboardMonitor?
    private var activityObserver: SystemActivityObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app. Do not read the real clipboard there.
        guard !Self.isRunningTests else {
            return
        }
        let monitor = ClipboardMonitor(pasteboard: SystemPasteboard(), history: history)
        let activityObserver = SystemActivityObserver(monitor: monitor)
        activityObserver.start()
        monitor.start()
        self.monitor = monitor
        self.activityObserver = activityObserver
    }
}
