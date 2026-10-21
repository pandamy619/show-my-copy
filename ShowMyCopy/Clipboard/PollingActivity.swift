import Foundation

/// Tells macOS that polling is work the user is waiting for.
///
/// The app has no windows on screen most of the time, so App Nap would otherwise slow its timers down and copies
/// would be picked up late, or replaced by the next copy before the monitor sees them.
@MainActor
protocol PollingActivity: AnyObject {
    func begin()
    func end()
}

@MainActor
final class ProcessPollingActivity: PollingActivity {
    private var token: (any NSObjectProtocol)?

    func begin() {
        guard token == nil else {
            return
        }
        // Prevents App Nap but still lets the Mac go to sleep when idle.
        token = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Watching the clipboard for new copies"
        )
    }

    func end() {
        guard let token else {
            return
        }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}
