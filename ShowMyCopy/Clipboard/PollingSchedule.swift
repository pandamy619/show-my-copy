import Foundation

/// When `ClipboardMonitor` looks at the pasteboard: on a timer while it is started and nothing pauses it.
///
/// macOS has no notification for pasteboard changes, so the monitor checks `changeCount` every `interval`. The
/// schedule ticks once right away when polling starts or resumes, then after every `interval`. While polling it
/// holds `activity`, so App Nap does not slow the timer down.
@MainActor
final class PollingSchedule {
    enum PauseReason: Hashable, Sendable {
        case systemSleep
        case displaySleep
        case screenLocked
        case sessionInactive
    }

    nonisolated static let defaultInterval: Duration = .milliseconds(500)

    /// What runs on every tick. The monitor sets it.
    var tick: @MainActor () -> Void = {}

    private let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let activity: any PollingActivity
    private var pollTask: Task<Void, Never>?
    private(set) var isStarted = false
    private(set) var pauseReasons: Set<PauseReason> = []

    init(
        interval: Duration = PollingSchedule.defaultInterval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        activity: any PollingActivity = ProcessPollingActivity()
    ) {
        self.interval = interval
        self.sleep = sleep
        self.activity = activity
    }

    var isPolling: Bool {
        pollTask != nil
    }

    /// Started and not paused: a change found now was made while the monitor was watching.
    var isWatching: Bool {
        isStarted && pauseReasons.isEmpty
    }

    func start() {
        isStarted = true
        update()
    }

    func stop() {
        isStarted = false
        update()
    }

    /// Stops polling while the Mac sleeps or the screen is locked. Polling resumes when every reason is cleared.
    func pause(for reason: PauseReason) {
        pauseReasons.insert(reason)
        update()
    }

    func resume(for reason: PauseReason) {
        pauseReasons.remove(reason)
        update()
    }

    /// Clears every pause reason.
    func resumeAll() {
        guard !pauseReasons.isEmpty else {
            return
        }
        pauseReasons.removeAll()
        update()
    }

    private func update() {
        if isWatching, pollTask == nil {
            activity.begin()
            tick()
            pollTask = Task { [weak self, interval, sleep] in
                while !Task.isCancelled {
                    do {
                        try await sleep(interval)
                    } catch {
                        // Cancelled: the loop ends below.
                    }
                    guard let self, !Task.isCancelled else {
                        return
                    }
                    self.tick()
                }
            }
        } else if !isWatching, let pollTask {
            pollTask.cancel()
            self.pollTask = nil
            activity.end()
        }
    }
}
