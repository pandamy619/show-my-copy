import Foundation

/// Decides when polling holds the App Nap activity (`PollingActivity`).
///
/// The trade-off: while the activity is held, macOS runs the polling timer on time, but the app keeps the CPU waking
/// twice a second; held all day, that shows as energy use for an app that is idle almost all the time. Without it,
/// App Nap throttles the timer of an app with no window on screen, which this app is most of the time, so a copy can
/// be seen seconds late, and a copy that another one replaces within that delay is missed.
///
/// Copies come in bursts, so the activity is held only where copies are likely: while the history window is open,
/// and for `holdAfterActivity` after polling starts or resumes (launch, wake, unlock), after each change seen on the
/// pasteboard and after the user switches to another app, which usually comes with copying and pasting. The first
/// copy after a quiet spell can still be seen late, but it is seen: the pasteboard keeps it until the next copy, and
/// the copies after it are seen on time. Outside those times polling goes on under App Nap, with a timer tolerance
/// (`PollingSchedule.tolerance`) so macOS can group its wakeups with others.
///
/// The hold is checked on every tick, so it ends at the first tick after its time is up.
@MainActor
final class PollingActivityPolicy {
    /// How long the activity is held after something that makes a copy likely.
    nonisolated static let holdAfterActivity: Duration = .seconds(60)

    private let activity: any PollingActivity
    private let now: @MainActor () -> ContinuousClock.Instant
    private var isPolling = false
    private var isWindowOpen = false
    private var holdsUntil: ContinuousClock.Instant?
    private var isHeld = false

    init(activity: any PollingActivity, now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.activity = activity
        self.now = now
    }

    /// Polling starts or resumes: copies made just before, or right after waking, are likely.
    func pollingStarted() {
        isPolling = true
        noteActivity()
    }

    /// Polling stops or pauses: nothing is held while nothing is polled.
    func pollingStopped() {
        isPolling = false
        update()
    }

    /// A change was seen on the pasteboard, or the user switched apps: hold for `holdAfterActivity` from now.
    func noteActivity() {
        holdsUntil = now() + Self.holdAfterActivity
        update()
    }

    /// The history window opened or closed. While it is open the activity is held.
    func setWindowOpen(_ isOpen: Bool) {
        isWindowOpen = isOpen
        if !isOpen {
            // The user just used the history, and may copy what they picked again: hold a while longer.
            holdsUntil = now() + Self.holdAfterActivity
        }
        update()
    }

    /// Called on every tick of the polling timer: ends a hold whose time is up.
    func tick() {
        update()
    }

    private func update() {
        let wanted = isPolling && (isWindowOpen || holdsUntil.map { now() < $0 } == true)
        if wanted, !isHeld {
            activity.begin()
            isHeld = true
        } else if !wanted, isHeld {
            activity.end()
            isHeld = false
        }
    }
}
