import Foundation

/// When `ClipboardMonitor` looks at the pasteboard: on a timer while it is started and nothing pauses it.
///
/// macOS has no notification for pasteboard changes, so the monitor checks `changeCount` every `interval`. The
/// schedule ticks once right away when polling starts or resumes, then after every `interval`, with `tolerance` so
/// macOS can group the wakeups. It holds `activity`, so App Nap does not slow the timer down, only while copies are
/// likely (`PollingActivityPolicy`).
@MainActor
final class PollingSchedule {
    enum PauseReason: Hashable, Sendable {
        case systemSleep
        case displaySleep
        case screenLocked
        case sessionInactive
    }

    nonisolated static let defaultInterval: Duration = .milliseconds(500)

    /// How late a tick may come, so macOS can fire it together with other timers. A fifth of the interval: a copy is
    /// still seen well within a second.
    nonisolated static let tolerance: Duration = .milliseconds(100)

    /// Sleeps with `tolerance`: the sleep the app polls with.
    nonisolated static let sleepWithTolerance: @Sendable (Duration) async throws -> Void = { duration in
        try await Task.sleep(for: duration, tolerance: tolerance)
    }

    /// What runs on every tick. The monitor sets it.
    var tick: @MainActor () -> Void = {}

    private let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let activity: PollingActivityPolicy
    private var pollTask: Task<Void, Never>?
    private(set) var isStarted = false
    private(set) var pauseReasons: Set<PauseReason> = []

    init(
        interval: Duration = PollingSchedule.defaultInterval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = PollingSchedule.sleepWithTolerance,
        activity: any PollingActivity = ProcessPollingActivity(),
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) {
        self.interval = interval
        self.sleep = sleep
        self.activity = PollingActivityPolicy(activity: activity, now: now)
    }

    /// Whether the App Nap activity is held now.
    var holdsActivity: Bool {
        activity.isHeld
    }

    /// A change was seen on the pasteboard, or the user switched apps: more copies are likely soon.
    func noteActivity() {
        activity.noteActivity()
    }

    /// The history window opened or closed.
    func setHistoryWindowOpen(_ isOpen: Bool) {
        activity.setWindowOpen(isOpen)
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
            activity.pollingStarted()
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
                    self.activity.tick()
                    self.tick()
                }
            }
        } else if !isWatching, let pollTask {
            pollTask.cancel()
            self.pollTask = nil
            activity.pollingStopped()
        }
    }
}
