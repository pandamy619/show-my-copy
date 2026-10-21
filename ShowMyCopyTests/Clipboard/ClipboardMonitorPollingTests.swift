import Foundation
import Testing

@testable import ShowMyCopy

/// Replaces `Task.sleep` in the polling loop. Each sleep lasts until the test calls `wakeAll()`.
@MainActor
final class ManualSleeper {
    private(set) var requestedDurations: [Duration] = []
    private var sleepers: [CheckedContinuation<Void, Never>] = []

    var sleepingCount: Int {
        sleepers.count
    }

    func sleep(for duration: Duration) async {
        requestedDurations.append(duration)
        await withCheckedContinuation { sleepers.append($0) }
    }

    func wakeAll() {
        let woken = sleepers
        sleepers.removeAll()
        for sleeper in woken {
            sleeper.resume()
        }
    }

    /// Lets other main-actor tasks run until the polling loop sleeps again. Does not wait for real time.
    func waitUntilSleeping() async {
        var turns = 0
        while sleepers.isEmpty, turns < 10_000 {
            turns += 1
            await Task.yield()
        }
    }

    /// Lets other main-actor tasks run for a while, for checks that nothing happens.
    func yieldForAWhile() async {
        for _ in 0..<100 {
            await Task.yield()
        }
    }
}

@MainActor
struct ClipboardMonitorPollingTests {
    private let pasteboard = FakePasteboard()
    private let history = ClipboardHistory()
    private let sleeper = ManualSleeper()

    private func makeMonitor() -> ClipboardMonitor {
        ClipboardMonitor(
            pasteboard: pasteboard,
            history: history,
            interval: .seconds(3),
            frontmostApp: { nil },
            sleep: { [sleeper] duration in await sleeper.sleep(for: duration) }
        )
    }

    @Test func pollingLoopPicksUpNewCopies() async {
        let monitor = makeMonitor()
        monitor.start()
        await sleeper.waitUntilSleeping()
        #expect(sleeper.requestedDurations == [.seconds(3)])

        pasteboard.copy("copied later")
        #expect(history.entries.isEmpty)

        sleeper.wakeAll()
        await sleeper.waitUntilSleeping()
        #expect(history.entries.map(\.text) == ["copied later"])
        #expect(sleeper.requestedDurations == [.seconds(3), .seconds(3)])

        monitor.stop()
        sleeper.wakeAll()
    }

    @Test func stoppedLoopDoesNotPollOrSleepAgain() async {
        let monitor = makeMonitor()
        monitor.start()
        await sleeper.waitUntilSleeping()

        monitor.stop()
        pasteboard.copy("copied after stop")
        sleeper.wakeAll()
        await sleeper.yieldForAWhile()

        #expect(history.entries.isEmpty)
        #expect(sleeper.sleepingCount == 0)
        #expect(sleeper.requestedDurations.count == 1)
    }
}

@MainActor
final class CountingActivity: PollingActivity {
    private(set) var beginCount = 0
    private(set) var endCount = 0

    var isActive: Bool {
        beginCount > endCount
    }

    func begin() {
        beginCount += 1
    }

    func end() {
        endCount += 1
    }
}

@MainActor
struct ClipboardMonitorActivityTests {
    private let pasteboard = FakePasteboard()
    private let history = ClipboardHistory()
    private let activity = CountingActivity()

    private func makeMonitor() -> ClipboardMonitor {
        ClipboardMonitor(pasteboard: pasteboard, history: history, frontmostApp: { nil }, activity: activity)
    }

    @Test func pollingHoldsTheActivityUntilStop() {
        let monitor = makeMonitor()
        #expect(!activity.isActive)

        monitor.start()
        monitor.start()
        #expect(activity.beginCount == 1)
        #expect(activity.isActive)

        monitor.stop()
        #expect(activity.endCount == 1)
        #expect(!activity.isActive)
    }

    @Test func pauseEndsTheActivityAndResumeBeginsItAgain() {
        let monitor = makeMonitor()
        monitor.start()
        monitor.pause(for: .screenLocked)
        monitor.pause(for: .displaySleep)
        #expect(!activity.isActive)
        #expect(activity.endCount == 1)

        monitor.resume(for: .screenLocked)
        #expect(!activity.isActive)
        monitor.resume(for: .displaySleep)
        #expect(activity.isActive)
        #expect(activity.beginCount == 2)
        monitor.stop()
    }

    @Test func pausedOrStoppedMonitorDoesNotBeginTheActivity() {
        let monitor = makeMonitor()
        monitor.pause(for: .systemSleep)
        monitor.start()
        monitor.stop()
        #expect(activity.beginCount == 0)
        #expect(activity.endCount == 0)
    }
}
