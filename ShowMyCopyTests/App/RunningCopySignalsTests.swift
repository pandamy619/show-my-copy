import Foundation
import Testing

@testable import ShowMyCopy

/// What the running copy was asked to do.
@MainActor
final class RunningCopyActions {
    private(set) var settingsShown = 0
    private(set) var quits = 0

    func showSettings() {
        settingsShown += 1
    }

    func quit() {
        quits += 1
    }
}

@MainActor
struct RunningCopySignalsTests {
    private let replacement = DebugBuildReplacement(quitRequest: Notification.Name("test.quitForNewerDebugBuild"))
    private let notifications = FakeNotifications()
    private let clock = ManualInstant()
    private let actions = RunningCopyActions()

    private func listen(debug: Bool) -> RunningCopySignals {
        let signals = RunningCopySignals(notifications: notifications, now: clock.read)
        signals.listen(
            showSettings: { [actions] in actions.showSettings() },
            replacement: debug ? replacement : nil,
            quit: { [actions] in actions.quit() }
        )
        return signals
    }

    @Test func aReleaseCopyListensOnlyForAnotherCopyStarting() {
        let signals = listen(debug: false)

        #expect(notifications.observedNames == [DuplicateLaunch.anotherCopyStarted])
        withExtendedLifetime(signals) {}
    }

    @Test func aDebugCopyAlsoListensForTheQuitRequest() {
        let signals = listen(debug: true)

        #expect(
            Set(notifications.observedNames) == [DuplicateLaunch.anotherCopyStarted, replacement.quitRequest])
        #expect(notifications.observedNames.count == 2)
        withExtendedLifetime(signals) {}
    }

    @Test(arguments: [false, true])
    func anotherCopyStartingShowsSettings(debug: Bool) {
        let signals = listen(debug: debug)

        notifications.post(DuplicateLaunch.anotherCopyStarted)

        #expect(actions.settingsShown == 1)
        #expect(actions.quits == 0)
        withExtendedLifetime(signals) {}
    }

    @Test func aReleaseCopyIgnoresTheQuitRequest() {
        let signals = listen(debug: false)

        notifications.post(replacement.quitRequest)

        #expect(actions.quits == 0)
        #expect(actions.settingsShown == 0)
        withExtendedLifetime(signals) {}
    }

    @Test func aDebugCopyQuitsWhenANewerDebugBuildAsks() {
        let signals = listen(debug: true)

        notifications.post(replacement.quitRequest)

        #expect(actions.quits == 1)
        #expect(actions.settingsShown == 0)
        withExtendedLifetime(signals) {}
    }

    @Test func settingsShowAtMostOncePerInterval() {
        let signals = listen(debug: false)

        notifications.post(DuplicateLaunch.anotherCopyStarted)
        notifications.post(DuplicateLaunch.anotherCopyStarted)
        clock.advance(by: RunningCopySignals.settingsInterval - .milliseconds(1))
        notifications.post(DuplicateLaunch.anotherCopyStarted)
        #expect(actions.settingsShown == 1)

        clock.advance(by: .milliseconds(1))
        notifications.post(DuplicateLaunch.anotherCopyStarted)
        #expect(actions.settingsShown == 2)
        withExtendedLifetime(signals) {}
    }

    /// Posting again and again does not keep Settings from showing once the interval has passed.
    @Test func ignoredRequestsDoNotExtendTheInterval() {
        let signals = listen(debug: false)

        notifications.post(DuplicateLaunch.anotherCopyStarted)
        for _ in 0..<5 {
            clock.advance(by: RunningCopySignals.settingsInterval / 5)
            notifications.post(DuplicateLaunch.anotherCopyStarted)
        }

        #expect(actions.settingsShown == 2)
        withExtendedLifetime(signals) {}
    }

    @Test func theIntervalIsAFewSeconds() {
        #expect(RunningCopySignals.settingsInterval >= .seconds(1))
        #expect(RunningCopySignals.settingsInterval <= .seconds(10))
    }

    @Test func theThrottleAcceptsTheFirstRequestAndThenOnePerInterval() {
        var throttle = RequestThrottle(interval: .seconds(3))
        let start = ContinuousClock.now
        let offsets: [Duration] = [.zero, .zero, .seconds(2), .seconds(3), .seconds(5), .seconds(6)]

        let accepted = offsets.map { throttle.accept(at: start + $0) }

        #expect(accepted == [true, false, false, true, false, true])
    }
}
