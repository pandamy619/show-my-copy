import Foundation
import Testing

@testable import ShowMyCopy

/// Remembers the names a copy posted, in order.
@MainActor
final class FakeInstanceSignals: InstanceSignalPosting {
    private(set) var posted: [Notification.Name] = []

    func post(_ name: Notification.Name) {
        posted.append(name)
    }
}

/// Another copy that is running until it has been looked at `quitsAfterLooks` times; nil never quits.
@MainActor
final class FakeOtherCopy {
    private let quitsAfterLooks: Int?
    private(set) var looks = 0

    init(quitsAfterLooks: Int?) {
        self.quitsAfterLooks = quitsAfterLooks
    }

    func isRunning() -> Bool {
        looks += 1
        guard let quitsAfterLooks else {
            return true
        }
        return looks <= quitsAfterLooks
    }
}

/// A sleep that returns at once and remembers how long it was asked to wait, or throws as if cancelled.
@MainActor
final class SleepRecorder {
    private(set) var durations: [Duration] = []
    var isCancelled = false

    var total: Duration {
        durations.reduce(.zero, +)
    }

    func sleep(_ duration: Duration) throws {
        if isCancelled {
            throw CancellationError()
        }
        durations.append(duration)
    }
}

@MainActor
struct DuplicateLaunchTests {
    private let replacement = DebugBuildReplacement(quitRequest: Notification.Name("test.quitForNewerDebugBuild"))

    private func launch(
        other: FakeOtherCopy, signals: FakeInstanceSignals, sleeper: SleepRecorder, debug: Bool
    ) -> DuplicateLaunch {
        DuplicateLaunch(
            anotherIsRunning: { other.isRunning() },
            signals: signals,
            sleep: { @MainActor duration in try sleeper.sleep(duration) },
            replacement: debug ? replacement : nil
        )
    }

    @Test(arguments: [false, true])
    func aCopyAloneKeepsRunningAndSignalsNothing(debug: Bool) async {
        let other = FakeOtherCopy(quitsAfterLooks: 0)
        let signals = FakeInstanceSignals()
        let sleeper = SleepRecorder()

        let outcome = await launch(other: other, signals: signals, sleeper: sleeper, debug: debug).resolve()

        #expect(outcome == .keepRunning)
        #expect(signals.posted.isEmpty)
        #expect(sleeper.durations.isEmpty)
    }

    @Test func aReleaseCopyAsksTheRunningOneToShowSettingsAndQuits() async {
        let other = FakeOtherCopy(quitsAfterLooks: nil)
        let signals = FakeInstanceSignals()
        let sleeper = SleepRecorder()

        let outcome = await launch(other: other, signals: signals, sleeper: sleeper, debug: false).resolve()

        #expect(outcome == .quit)
        #expect(signals.posted == [DuplicateLaunch.anotherCopyStarted])
        // It never asks the other copy to quit, so it does not wait for it either.
        #expect(sleeper.durations.isEmpty)
        #expect(other.looks == 1)
    }

    @Test func aDebugCopyReplacesAnOlderDebugCopyThatQuits() async {
        let other = FakeOtherCopy(quitsAfterLooks: 3)
        let signals = FakeInstanceSignals()
        let sleeper = SleepRecorder()

        let outcome = await launch(other: other, signals: signals, sleeper: sleeper, debug: true).resolve()

        #expect(outcome == .keepRunning)
        // Only the quit request: the copy that quit has no Settings to show.
        #expect(signals.posted == [replacement.quitRequest])
        #expect(sleeper.durations == Array(repeating: DuplicateLaunch.pollInterval, count: 3))
    }

    @Test func aDebugCopyQuitsAndShowsTheRunningOneWhenItDoesNotQuit() async {
        // A Release copy, or an older build, does not listen for the quit request.
        let other = FakeOtherCopy(quitsAfterLooks: nil)
        let signals = FakeInstanceSignals()
        let sleeper = SleepRecorder()

        let outcome = await launch(other: other, signals: signals, sleeper: sleeper, debug: true).resolve()

        #expect(outcome == .quit)
        #expect(signals.posted == [replacement.quitRequest, DuplicateLaunch.anotherCopyStarted])
        #expect(sleeper.total == DuplicateLaunch.replacementBudget)
        #expect(sleeper.durations.allSatisfy { $0 == DuplicateLaunch.pollInterval })
    }

    @Test func aDebugCopyWhoseWaitIsCancelledQuitsAndShowsTheRunningOne() async {
        let other = FakeOtherCopy(quitsAfterLooks: 1)
        let signals = FakeInstanceSignals()
        let sleeper = SleepRecorder()
        sleeper.isCancelled = true

        let outcome = await launch(other: other, signals: signals, sleeper: sleeper, debug: true).resolve()

        #expect(outcome == .quit)
        #expect(signals.posted == [replacement.quitRequest, DuplicateLaunch.anotherCopyStarted])
    }

    /// The old copy finishes saving images before it quits, for at most `AppContainer.quitBudget`.
    @Test func theWaitOutlastsTheOldCopysQuitBudget() {
        #expect(DuplicateLaunch.replacementBudget > AppContainer.quitBudget)
        #expect(DuplicateLaunch.pollInterval > .zero)
        #expect(DuplicateLaunch.pollInterval < DuplicateLaunch.replacementBudget)
    }

    /// Every build posts and observes the same fixed name, also a Debug build next to an installed Release copy.
    @Test func theSignalHasAFixedNameOfItsOwn() {
        #expect(DuplicateLaunch.anotherCopyStarted.rawValue == "com.pandamy619.ShowMyCopy.anotherCopyStarted")
    }
}
