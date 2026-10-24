import Foundation
import Testing

@testable import ShowMyCopy

struct TimeLimitTests {
    private let timers = ManualTimers()

    @Test func givesTheResultOfWorkThatFinishesInTime() async {
        #expect(await TimeLimit.run(within: .seconds(10), sleep: timers.sleep) { 7 } == 7)
    }

    @Test func givesNilWhenTheTimeIsUpAndCancelsTheWork() async {
        let sleep = timers.sleep
        let running = Task {
            await TimeLimit.run(within: .milliseconds(50), sleep: sleep) { () -> Bool in
                await suspendUntilCancelled()
                return Task.isCancelled
            }
        }
        await timers.waitForSleep(of: .milliseconds(50))
        timers.fire(.milliseconds(50))
        #expect(await running.value == nil)
    }

    /// Work that ignores cancellation, as a synchronous file system call does, does not hold the caller.
    @Test func doesNotWaitForWorkThatCannotBeStopped() async {
        let gate = AsyncGate()
        gate.arm()
        let sleep = timers.sleep
        let running = Task {
            await TimeLimit.run(within: .milliseconds(50), sleep: sleep) { () -> Int in
                await gate.pass()
                return 7
            }
        }
        await gate.waitUntilReached()
        await timers.waitForSleep(of: .milliseconds(50))
        timers.fire(.milliseconds(50))
        #expect(await running.value == nil)
        gate.open()
    }

    @Test func givesNilWhenTheCallerIsCancelled() async {
        let sleep = timers.sleep
        let gate = AsyncGate()
        gate.arm()
        let running = Task {
            await TimeLimit.run(within: .seconds(10), sleep: sleep) { () -> Int in
                await gate.pass()
                return 7
            }
        }
        await gate.waitUntilReached()
        running.cancel()
        #expect(await running.value == nil)
        gate.open()
    }
}
