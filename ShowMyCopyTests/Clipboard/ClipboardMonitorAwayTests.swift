import Foundation
import Testing

@testable import ShowMyCopy

/// What happens to passwords while the monitor is paused, because the Mac sleeps, its displays sleep, the screen is
/// locked or another user is active:
/// - Expired passwords go as soon as the Mac or its displays wake or the screen is unlocked, also while polling stays
///   paused for another reason, such as a screen that is still locked after the Mac woke up.
/// - A password manager that empties the clipboard meanwhile is noticed after the pause. The 3-minute window is
///   measured to when the pause began, the earliest the clipboard can have been emptied unseen, and only when emptying
///   it was the only change since: then the clipboard was emptied of the entry the monitor saw last.
@MainActor
struct ClipboardMonitorAwayTests {
    private let pasteboard = FakePasteboard()
    private let history = InMemoryHistoryStore()
    private let environment = MonitorEnvironment()
    private let safari = SourceApp(bundleIdentifier: "com.apple.Safari", name: "Safari")

    /// A started monitor that saves passwords for a minute and has recorded "before" and then a marked password.
    private func makeMonitorWithSavedPassword() -> ClipboardMonitor {
        environment.savePasswords(for: 60)
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        pasteboard.copy("before")
        monitor.start()
        pasteboard.copy("hunter2", markers: [PasteboardMarker.concealed])
        monitor.poll()
        return monitor
    }

    /// A started monitor that has recorded "older" and then "hunter2", copied without a marker from a browser
    /// extension.
    private func makeMonitorWithUnmarkedPassword() -> ClipboardMonitor {
        environment.frontmostApp = safari
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        pasteboard.copy("older")
        monitor.start()
        pasteboard.copy("hunter2")
        monitor.poll()
        return monitor
    }

    // MARK: Expiry

    @Test(arguments: [
        PollingSchedule.PauseReason.systemSleep, PollingSchedule.PauseReason.displaySleep,
        PollingSchedule.PauseReason.sessionInactive,
    ])
    func anExpiredPasswordGoesWhenTheMacWakesWhileTheScreenIsStillLocked(
        wake: PollingSchedule.PauseReason
    ) {
        let monitor = makeMonitorWithSavedPassword()
        let passwordChange = pasteboard.changeCount
        monitor.pause(for: .screenLocked)
        monitor.pause(for: wake)
        environment.now += 3600

        monitor.resume(for: wake)

        #expect(!monitor.isPolling)
        #expect(history.entries.map(\.text) == ["before"])
        // Still exactly the password the app recorded, so it leaves the clipboard too.
        #expect(pasteboard.clearedChangeCounts == [passwordChange])
        monitor.stop()
    }

    @Test func anExpiredPasswordGoesWhenTheScreenIsUnlockedWhileTheDisplaysStillSleep() {
        let monitor = makeMonitorWithSavedPassword()
        monitor.pause(for: .displaySleep)
        monitor.pause(for: .screenLocked)
        environment.now += 60

        monitor.resume(for: .screenLocked)

        #expect(!monitor.isPolling)
        #expect(history.entries.map(\.text) == ["before"])
        monitor.stop()
    }

    @Test func aPasswordWhoseTimeIsNotUpStaysAfterWaking() {
        let monitor = makeMonitorWithSavedPassword()
        monitor.pause(for: .screenLocked)
        monitor.pause(for: .systemSleep)
        environment.now += 59

        monitor.resume(for: .systemSleep)

        #expect(history.entries.map(\.text) == ["hunter2", "before"])
        #expect(pasteboard.clearedChangeCounts.isEmpty)
        monitor.stop()
    }

    // MARK: Clipboard emptied while away

    /// The scenario of the review: the password is copied, the Mac is locked a few seconds later, the extension empties
    /// the clipboard 90 seconds after the copy, and the user unlocks 10 minutes after that.
    @Test func aClipboardEmptiedWhileTheScreenWasLockedRemovesTheEntryAfterUnlocking() {
        let monitor = makeMonitorWithUnmarkedPassword()
        environment.now += 5
        monitor.pause(for: .screenLocked)
        environment.now += 85
        pasteboard.clear()
        environment.now += 600

        monitor.resume(for: .screenLocked)
        #expect(history.entries.map(\.text) == ["hunter2", "older"])
        monitor.poll()

        #expect(history.entries.map(\.text) == ["older"])
        #expect(history.currentEntryID == nil)
        monitor.stop()
    }

    @Test func aClipboardEmptiedDuringSleepRemovesTheEntryAfterWaking() {
        let monitor = makeMonitorWithUnmarkedPassword()
        environment.now += 170
        monitor.pause(for: .systemSleep)
        pasteboard.clear()
        environment.now += 3600

        monitor.resume(for: .systemSleep)
        monitor.poll()

        #expect(history.entries.map(\.text) == ["older"])
        monitor.stop()
    }

    /// Saved as a password, its time counted from when the pause began, the latest it can have been copied.
    @Test func withPasswordsSavedTheEntryIsConcealedFromWhenThePauseBegan() throws {
        environment.savePasswords(for: 600)
        let monitor = makeMonitorWithUnmarkedPassword()
        environment.now += 5
        let locked = environment.now
        monitor.pause(for: .screenLocked)
        pasteboard.clear()
        environment.now += 300

        monitor.resume(for: .screenLocked)
        monitor.poll()

        let entry = try #require(history.entries.first)
        #expect(entry.isConcealed)
        #expect(entry.expiresAt == locked + 600)
        #expect(history.entries.map(\.text) == ["hunter2", "older"])
        monitor.stop()
    }

    @Test func aLockMoreThanThreeMinutesAfterTheCopyKeepsTheEntry() {
        let monitor = makeMonitorWithUnmarkedPassword()
        environment.now += ClearedClipboardCheck.window + 1
        monitor.pause(for: .screenLocked)
        pasteboard.clear()
        environment.now += 60

        monitor.resume(for: .screenLocked)
        monitor.poll()

        #expect(history.entries.map(\.text) == ["hunter2", "older"])
        #expect(history.entries.first?.isConcealed == false)
        monitor.stop()
    }

    /// Something else was copied before the clipboard was emptied, for example on another device: what was emptied is
    /// not known to be the entry, so it stays.
    @Test func anotherChangeBeforeTheClearWhileLockedKeepsTheEntry() {
        let monitor = makeMonitorWithUnmarkedPassword()
        environment.now += 5
        monitor.pause(for: .screenLocked)
        environment.now += 30
        pasteboard.copy("from another device")
        pasteboard.clear()
        environment.now += 600

        monitor.resume(for: .screenLocked)
        monitor.poll()

        #expect(history.entries.map(\.text) == ["hunter2", "older"])
        monitor.stop()
    }

    /// Nothing changed while the screen was locked: a clear long after unlocking is measured from when it is seen.
    @Test func aClearSeenLongAfterUnlockingIsMeasuredFromWhenItIsSeen() {
        let monitor = makeMonitorWithUnmarkedPassword()
        environment.now += 5
        monitor.pause(for: .screenLocked)
        environment.now += 20
        monitor.resume(for: .screenLocked)
        environment.now += ClearedClipboardCheck.window

        pasteboard.clear()
        monitor.poll()
        monitor.poll()

        #expect(history.entries.map(\.text) == ["hunter2", "older"])
        monitor.stop()
    }

    @Test func aPauseBeginsOnlyOnceWhileSeveralReasonsPause() {
        let monitor = makeMonitorWithUnmarkedPassword()
        environment.now += 5
        monitor.pause(for: .screenLocked)
        environment.now += ClearedClipboardCheck.window
        // The displays go to sleep later: the pause began when the screen was locked.
        monitor.pause(for: .displaySleep)
        pasteboard.clear()
        environment.now += 60

        monitor.resume(for: .displaySleep)
        monitor.resume(for: .screenLocked)
        monitor.poll()

        #expect(history.entries.map(\.text) == ["older"])
        monitor.stop()
    }
}
