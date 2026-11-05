/// Whether another process of this app is running, so this one quits before it opens the history.
///
/// Two processes would share one saved history: each records every copy under its own ID and neither sees the
/// other's records, so after the next launch every entry is listed twice. macOS does not prevent it when the copies
/// are at different places, such as a build started from Xcode while the installed app runs, and the app has no Dock
/// or menu bar icon that would show the other one. The one that was running first keeps running.
enum SingleInstance {
    /// A running copy of an app, as `NSRunningApplication` describes it.
    struct RunningCopy: Equatable, Sendable {
        let bundleIdentifier: String?
        let processIdentifier: Int32
        let isTerminated: Bool
    }

    /// Whether `running` has a live process of the app with `bundleIdentifier` other than `ownProcess`. Without a
    /// bundle identifier nothing is known to be the same app.
    static func anotherIsRunning(bundleIdentifier: String?, ownProcess: Int32, running: [RunningCopy]) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return false
        }
        return running.contains { copy in
            copy.bundleIdentifier == bundleIdentifier && copy.processIdentifier != ownProcess
                && !copy.isTerminated
        }
    }
}
