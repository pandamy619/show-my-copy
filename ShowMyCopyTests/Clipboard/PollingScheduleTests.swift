import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct PollingScheduleTests {
    private let sleeper = ManualSleeper()
    private let activity = CountingActivity()

    private func makeSchedule(ticks: TickCounter) -> PollingSchedule {
        let schedule = PollingSchedule(
            interval: .seconds(2), sleep: { [sleeper] in await sleeper.sleep(for: $0) }, activity: activity)
        schedule.tick = { ticks.value += 1 }
        return schedule
    }

    @Test func ticksAtOnceAndAfterEveryInterval() async {
        let ticks = TickCounter()
        let schedule = makeSchedule(ticks: ticks)
        schedule.start()
        #expect(ticks.value == 1)
        await sleeper.waitUntilSleeping()
        sleeper.wakeAll()
        await sleeper.waitUntilSleeping()
        #expect(ticks.value == 2)
        #expect(sleeper.requestedDurations == [.seconds(2), .seconds(2)])
        schedule.stop()
        sleeper.wakeAll()
    }

    @Test func pausedScheduleDoesNotTickUntilEveryReasonIsGone() {
        let ticks = TickCounter()
        let schedule = makeSchedule(ticks: ticks)
        schedule.pause(for: .screenLocked)
        schedule.pause(for: .systemSleep)
        schedule.start()
        #expect(ticks.value == 0)
        #expect(!schedule.isWatching)

        schedule.resume(for: .screenLocked)
        #expect(ticks.value == 0)
        schedule.resumeAll()
        #expect(ticks.value == 1)
        #expect(schedule.isWatching)
        #expect(activity.isActive)
        schedule.stop()
        #expect(!activity.isActive)
    }
}

@MainActor
final class TickCounter {
    var value = 0
}

@MainActor
struct HistoryExpiryTests {
    @Test func removesThePasswordsWhoseTimeIsUp() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let history = ClipboardHistory()
        history.record(text: "kept", sourceApp: nil, at: start)
        history.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)
        let environment = MonitorEnvironment()
        environment.now = start + 59
        let expiry = HistoryExpiry(history: history, now: { environment.now })

        expiry.removeExpired()
        #expect(history.entries.count == 2)
        environment.now = start + 60
        expiry.removeExpired()
        #expect(history.entries.map(\.text) == ["kept"])
    }

    @Test func removesTheEntriesPastTheAgeLimit() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let history = InMemoryHistoryStore(retention: RetentionPolicy(maxAge: .seconds(3600)), now: { start })
        history.record(text: "old", sourceApp: nil, at: start - 3600)
        history.record(text: "recent", sourceApp: nil, at: start)
        let environment = MonitorEnvironment()
        environment.now = start + 3599
        let expiry = HistoryExpiry(history: history, now: { environment.now })

        expiry.removeExpired()
        #expect(history.entries.map(\.text) == ["recent"])
        environment.now = start + 3600
        expiry.removeExpired()
        #expect(history.entries.isEmpty)
    }
}
