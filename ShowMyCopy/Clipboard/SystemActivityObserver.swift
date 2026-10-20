import AppKit

/// Pauses the clipboard monitor while the Mac sleeps, the displays sleep, the screen is locked
/// or another user is active.
@MainActor
final class SystemActivityObserver {
    private let monitor: ClipboardMonitor
    private var observations: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    init(monitor: ClipboardMonitor) {
        self.monitor = monitor
    }

    func start() {
        guard observations.isEmpty else {
            return
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.pause(for: .systemSleep) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.resume(for: .systemSleep) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.pause(for: .displaySleep) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.resume(for: .displaySleep) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.pause(for: .sessionInactive) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.resume(for: .sessionInactive) }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.pause(for: .screenLocked) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.resume(for: .screenLocked) }
    }

    func stop() {
        for observation in observations {
            observation.center.removeObserver(observation.token)
        }
        observations.removeAll()
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        action: @escaping @MainActor @Sendable (ClipboardMonitor) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak monitor] _ in
            MainActor.assumeIsolated {
                guard let monitor else {
                    return
                }
                action(monitor)
            }
        }
        observations.append((center, token))
    }
}
