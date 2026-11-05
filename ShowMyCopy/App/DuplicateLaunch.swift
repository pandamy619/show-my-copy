import Foundation

/// Posts a notification to the other copies of the app that carries nothing but its name.
@MainActor
protocol InstanceSignalPosting: AnyObject {
    func post(_ name: Notification.Name)
}

/// How a Debug build takes over from an older Debug build that is still running. Only Debug builds make one
/// (`#if DEBUG` in `AppDelegate`); Release builds have none, so they neither ask another copy to quit nor quit when
/// asked, and any app could post the request.
struct DebugBuildReplacement: Sendable {
    /// The distributed notification a newer Debug build posts and a running Debug build quits on.
    let quitRequest: Notification.Name
}

/// What a copy of the app does at launch when another copy is already running.
///
/// The app has no Dock or menu bar icon, so a copy that just quits looks like nothing happened. It asks the running
/// copy to show its Settings (`anotherCopyStarted`), which `RunningCopySignals` does. Opening the same app again from
/// Finder or Launchpad never gets here: macOS brings the running process to the front and calls
/// `applicationShouldHandleReopen` there instead. This is for another copy at another place, such as a build from
/// Xcode while the installed app runs.
///
/// A Debug build with a `replacement` asks the running copy to quit first, and keeps running once it has: an older
/// Debug build quits, a Release build ignores the request, and then this copy quits as a Release build would.
@MainActor
final class DuplicateLaunch {
    enum Outcome: Equatable, Sendable {
        case keepRunning
        case quit
    }

    /// Posted by a copy that quits at launch because another one runs. Fixed, so every build of the app posts and
    /// observes the same name. Any app can post it; the running copy only shows its own Settings, at most once per
    /// `RunningCopySignals.settingsInterval`.
    nonisolated static let anotherCopyStarted = Notification.Name("com.pandamy619.ShowMyCopy.anotherCopyStarted")

    /// How often a Debug build looks whether the copy it asked to quit has quit.
    nonisolated static let pollInterval: Duration = .milliseconds(100)

    /// How long a Debug build waits for that. The other copy may first finish saving images, for at most
    /// `AppContainer.quitBudget`.
    nonisolated static let replacementBudget: Duration = AppContainer.quitBudget + .seconds(3)

    private let anotherIsRunning: @MainActor () -> Bool
    private let signals: any InstanceSignalPosting
    private let sleep: @Sendable (Duration) async throws -> Void
    private let replacement: DebugBuildReplacement?

    /// `anotherIsRunning` tells whether another process of the app runs now (`SingleInstance.anotherIsRunning`).
    init(
        anotherIsRunning: @escaping @MainActor () -> Bool,
        signals: any InstanceSignalPosting,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        replacement: DebugBuildReplacement?
    ) {
        self.anotherIsRunning = anotherIsRunning
        self.signals = signals
        self.sleep = sleep
        self.replacement = replacement
    }

    /// Whether this copy keeps running. When it quits, the running copy has been asked to show Settings.
    func resolve() async -> Outcome {
        guard anotherIsRunning() else {
            return .keepRunning
        }
        if let replacement {
            AppLogger.app.notice("Another copy of the app is running; asking it to quit for this debug build")
            signals.post(replacement.quitRequest)
            if await otherCopyQuit() {
                AppLogger.app.notice("The other copy quit; this debug build keeps running")
                return .keepRunning
            }
            // The developer's way out: a Release copy never quits on request, so that no other app can quit it.
            AppLogger.app.notice(
                """
                The other copy did not quit: it is a release build or an older one. Quitting this debug build; \
                to run it, quit the other copy first: pkill -x ShowMyCopy
                """)
        } else {
            AppLogger.app.notice("Another copy of the app is running; showing its settings and quitting this one")
        }
        signals.post(Self.anotherCopyStarted)
        return .quit
    }

    /// Whether no other copy runs any more within `replacementBudget`. Cancelled, it stops waiting.
    private func otherCopyQuit() async -> Bool {
        var waited = Duration.zero
        while waited < Self.replacementBudget {
            do {
                try await sleep(Self.pollInterval)
            } catch {
                return false
            }
            waited += Self.pollInterval
            if !anotherIsRunning() {
                return true
            }
        }
        return false
    }
}
