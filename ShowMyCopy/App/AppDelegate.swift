import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let history = ClipboardHistory()
    private var monitor: ClipboardMonitor?
    private var activityObserver: SystemActivityObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = ClipboardMonitor(pasteboard: SystemPasteboard(), history: history)
        let activityObserver = SystemActivityObserver(monitor: monitor)
        activityObserver.start()
        monitor.start()
        self.monitor = monitor
        self.activityObserver = activityObserver
    }
}
