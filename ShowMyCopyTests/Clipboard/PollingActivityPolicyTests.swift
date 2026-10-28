import Foundation
import Testing

@testable import ShowMyCopy

/// When polling keeps App Nap away: while the history window is open and for a while after anything that makes a
/// copy likely, never all day.
@MainActor
struct PollingActivityPolicyTests {
    private let activity = CountingActivity()
    private let clock = ManualInstant()
    private let hold = PollingActivityPolicy.holdAfterActivity

    private func makePolicy() -> PollingActivityPolicy {
        PollingActivityPolicy(activity: activity, now: clock.read)
    }

    @Test func holdsForAMinuteAfterPollingStartsThenLetsAppNapIn() {
        let policy = makePolicy()
        policy.pollingStarted()
        #expect(activity.isActive)

        clock.advance(by: hold - .seconds(1))
        policy.tick()
        #expect(activity.isActive)
        clock.advance(by: .seconds(1))
        policy.tick()
        #expect(!activity.isActive)
        #expect(activity.beginCount == 1)
        #expect(activity.endCount == 1)
    }

    @Test func eachChangeHoldsItAgain() {
        let policy = makePolicy()
        policy.pollingStarted()
        clock.advance(by: hold - .seconds(1))
        policy.noteActivity()
        clock.advance(by: hold - .seconds(1))
        policy.tick()
        #expect(activity.isActive)
        #expect(activity.beginCount == 1)

        clock.advance(by: .seconds(5))
        policy.tick()
        #expect(!activity.isActive)
        policy.noteActivity()
        #expect(activity.isActive)
        #expect(activity.beginCount == 2)
    }

    @Test func holdsWhileTheHistoryWindowIsOpenAndAMinuteAfter() {
        let policy = makePolicy()
        policy.pollingStarted()
        policy.setWindowOpen(true)
        clock.advance(by: hold * 10)
        policy.tick()
        #expect(activity.isActive)

        policy.setWindowOpen(false)
        #expect(activity.isActive)
        clock.advance(by: hold)
        policy.tick()
        #expect(!activity.isActive)
    }

    @Test func holdsNothingWhileNotPolling() {
        let policy = makePolicy()
        policy.setWindowOpen(true)
        policy.noteActivity()
        #expect(!activity.isActive)

        policy.pollingStarted()
        #expect(activity.isActive)
        policy.pollingStopped()
        #expect(!activity.isActive)
        policy.tick()
        #expect(!activity.isActive)
        #expect(activity.beginCount == 1)
        #expect(activity.endCount == 1)
    }

    @Test func budgetsAreShort() {
        #expect(PollingActivityPolicy.holdAfterActivity == .seconds(60))
        #expect(PollingSchedule.tolerance == .milliseconds(100))
        #expect(PollingSchedule.tolerance * 5 == PollingSchedule.defaultInterval)
    }
}

@MainActor
struct ClipboardMonitorAppNapTests {
    private let pasteboard = FakePasteboard()
    private let activity = CountingActivity()
    private let clock = ManualInstant()
    private let sleeper = ManualSleeper()

    private func makeMonitor() -> ClipboardMonitor {
        MonitorFactory.make(
            pasteboard: pasteboard, history: InMemoryHistoryStore(),
            sleep: { [sleeper] in await sleeper.sleep(for: $0) }, activity: activity, activityClock: clock.read)
    }

    /// Runs one tick of the polling loop.
    private func tick() async {
        sleeper.wakeAll()
        await sleeper.waitUntilSleeping()
    }

    @Test func aQuietMonitorLetsAppNapInAndACopyKeepsItAwayAgain() async {
        let monitor = makeMonitor()
        monitor.start()
        await sleeper.waitUntilSleeping()
        clock.advance(by: PollingActivityPolicy.holdAfterActivity)
        await tick()
        #expect(!activity.isActive)
        #expect(monitor.isPolling)

        pasteboard.copy("new")
        await tick()
        #expect(activity.isActive)
        monitor.stop()
        sleeper.wakeAll()
    }

    @Test func theOpenHistoryWindowKeepsAppNapAway() async {
        let monitor = makeMonitor()
        monitor.start()
        await sleeper.waitUntilSleeping()
        monitor.historyWindowOpened(true)
        clock.advance(by: PollingActivityPolicy.holdAfterActivity * 3)
        await tick()
        #expect(activity.isActive)

        monitor.historyWindowOpened(false)
        clock.advance(by: PollingActivityPolicy.holdAfterActivity)
        await tick()
        #expect(!activity.isActive)
        monitor.stop()
        sleeper.wakeAll()
    }
}
