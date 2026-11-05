import Foundation

/// Accepts one request, then none until `interval` has passed since the last one it accepted.
struct RequestThrottle: Sendable {
    let interval: Duration
    private var lastAccepted: ContinuousClock.Instant?

    init(interval: Duration) {
        self.interval = interval
    }

    mutating func accept(at now: ContinuousClock.Instant) -> Bool {
        if let lastAccepted, now - lastAccepted < interval {
            return false
        }
        lastAccepted = now
        return true
    }
}

/// What the running copy of the app does when another copy signals it (`DuplicateLaunch`).
///
/// The signals are distributed notifications, which any app on the Mac can post, so each one only ever leads to
/// something harmless. `DuplicateLaunch.anotherCopyStarted` shows the app's own Settings window, at most once per
/// `settingsInterval`. A Debug build with a `replacement` also quits on its quit request; a Release build never
/// observes one. Nothing a notification carries is read: the handlers get only the name, which is how the
/// sandbox lets the other copy post it (without `userInfo`).
@MainActor
final class RunningCopySignals {
    /// How often another copy starting can show Settings, so posting the name in a loop cannot keep pulling the
    /// window to the front.
    nonisolated static let settingsInterval: Duration = .seconds(3)

    private let notifications: any NotificationObserving
    private let now: @MainActor () -> ContinuousClock.Instant
    private var settingsRequests = RequestThrottle(interval: settingsInterval)

    init(notifications: any NotificationObserving, now: @escaping @MainActor () -> ContinuousClock.Instant) {
        self.notifications = notifications
        self.now = now
    }

    func listen(
        showSettings: @escaping @MainActor @Sendable () -> Void,
        replacement: DebugBuildReplacement?,
        quit: @escaping @MainActor @Sendable () -> Void
    ) {
        notifications.observe(DuplicateLaunch.anotherCopyStarted) { [weak self] in
            guard let self, self.settingsRequests.accept(at: self.now()) else {
                return
            }
            AppLogger.app.notice("Another copy of the app started and quit; showing settings")
            showSettings()
        }
        if let replacement {
            notifications.observe(replacement.quitRequest) {
                AppLogger.app.notice("A newer debug build asked this one to quit")
                quit()
            }
        }
    }
}
