import AppKit

/// Pauses the clipboard monitor while the Mac sleeps, the displays sleep, the screen is locked
/// or another user is active.
@MainActor
final class SystemActivityObserver {
    nonisolated static let screenIsLockedNotification = Notification.Name("com.apple.screenIsLocked")
    nonisolated static let screenIsUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    private let monitor: ClipboardMonitor
    private let workspace: any NotificationObserving
    private let distributed: any NotificationObserving
    private let isScreenLocked: @MainActor () -> Bool
    private let isSessionActive: @MainActor () -> Bool
    private var isStarted = false

    /// Called when the user leaves the Mac: it starts to sleep, the displays sleep, the screen locks or another
    /// user switches in. Windows that show the history close here, so it is not on screen for the next person.
    var onUserAway: (@MainActor () -> Void)?

    init(
        monitor: ClipboardMonitor,
        workspace: any NotificationObserving = NotificationCenterObserver(
            center: NSWorkspace.shared.notificationCenter
        ),
        distributed: any NotificationObserving = DistributedNotificationObserver(),
        isScreenLocked: @escaping @MainActor () -> Bool = { ConsoleSession.isScreenLocked() },
        isSessionActive: @escaping @MainActor () -> Bool = { ConsoleSession.isActive() }
    ) {
        self.monitor = monitor
        self.workspace = workspace
        self.distributed = distributed
        self.isScreenLocked = isScreenLocked
        self.isSessionActive = isSessionActive
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        observe(workspace, NSWorkspace.willSleepNotification, away: .systemSleep)
        observe(workspace, NSWorkspace.didWakeNotification, back: .systemSleep)
        observe(workspace, NSWorkspace.screensDidSleepNotification, away: .displaySleep)
        observe(workspace, NSWorkspace.screensDidWakeNotification, back: .displaySleep)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, away: .sessionInactive)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, back: .sessionInactive)
        observe(distributed, Self.screenIsLockedNotification, away: .screenLocked)
        observe(distributed, Self.screenIsUnlockedNotification, back: .screenLocked)
    }

    func stop() {
        workspace.removeAllObservers()
        distributed.removeAllObservers()
        isStarted = false
    }

    /// Clears pause reasons that are no longer true.
    ///
    /// A notification that ends a pause can be missed or arrive late. A reason left behind would stop recording
    /// until the app restarts, so the state is checked again whenever the Mac or its displays wake up.
    func reconcile() {
        if monitor.pauseReasons.contains(.screenLocked), !isScreenLocked() {
            monitor.resume(for: .screenLocked)
        }
        if monitor.pauseReasons.contains(.sessionInactive), isSessionActive() {
            monitor.resume(for: .sessionInactive)
        }
    }

    private func observe(_ center: any NotificationObserving, _ name: Notification.Name, away reason: PauseReason) {
        center.observe(name) { [weak self] in
            guard let self else {
                return
            }
            self.monitor.pause(for: reason)
            self.onUserAway?()
        }
    }

    private func observe(_ center: any NotificationObserving, _ name: Notification.Name, back reason: PauseReason) {
        center.observe(name) { [weak self] in
            guard let self else {
                return
            }
            self.monitor.resume(for: reason)
            self.reconcile()
        }
    }

    private typealias PauseReason = ClipboardMonitor.PauseReason
}
