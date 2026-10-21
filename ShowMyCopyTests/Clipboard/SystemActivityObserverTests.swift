import AppKit
import Testing

@testable import ShowMyCopy

/// Stands in for a notification center. `post` calls the handlers right away.
@MainActor
final class FakeNotifications: NotificationObserving {
    private var handlers: [Notification.Name: [@MainActor @Sendable () -> Void]] = [:]

    var observedNames: [Notification.Name] {
        handlers.flatMap { name, list in Array(repeating: name, count: list.count) }
    }

    func observe(_ name: Notification.Name, handler: @escaping @MainActor @Sendable () -> Void) {
        handlers[name, default: []].append(handler)
    }

    func removeAllObservers() {
        handlers.removeAll()
    }

    func post(_ name: Notification.Name) {
        for handler in handlers[name] ?? [] {
            handler()
        }
    }
}

@MainActor
final class CallCounter {
    private(set) var count = 0

    func call() {
        count += 1
    }
}

/// What the window server would report about the login session.
@MainActor
final class FakeSessionState {
    var isScreenLocked = false
    var isActive = true
}

@MainActor
struct SystemActivityObserverTests {
    enum Center: Sendable {
        case workspace
        case distributed
    }

    struct Pair {
        let center: Center
        let away: Notification.Name
        let back: Notification.Name
    }

    nonisolated static let reasons: [ClipboardMonitor.PauseReason] = [
        .systemSleep, .displaySleep, .sessionInactive, .screenLocked,
    ]

    static func pair(for reason: ClipboardMonitor.PauseReason) -> Pair {
        switch reason {
        case .systemSleep:
            Pair(center: .workspace, away: NSWorkspace.willSleepNotification, back: NSWorkspace.didWakeNotification)
        case .displaySleep:
            Pair(
                center: .workspace,
                away: NSWorkspace.screensDidSleepNotification,
                back: NSWorkspace.screensDidWakeNotification
            )
        case .sessionInactive:
            Pair(
                center: .workspace,
                away: NSWorkspace.sessionDidResignActiveNotification,
                back: NSWorkspace.sessionDidBecomeActiveNotification
            )
        case .screenLocked:
            Pair(
                center: .distributed,
                away: SystemActivityObserver.screenIsLockedNotification,
                back: SystemActivityObserver.screenIsUnlockedNotification
            )
        }
    }

    private let workspace = FakeNotifications()
    private let distributed = FakeNotifications()
    private let session = FakeSessionState()
    private let monitor = ClipboardMonitor(
        pasteboard: FakePasteboard(),
        history: ClipboardHistory(),
        frontmostApp: { nil },
        activity: CountingActivity()
    )

    private func makeObserver() -> SystemActivityObserver {
        SystemActivityObserver(
            monitor: monitor,
            workspace: workspace,
            distributed: distributed,
            isScreenLocked: { [session] in session.isScreenLocked },
            isSessionActive: { [session] in session.isActive }
        )
    }

    private func post(_ name: Notification.Name, to center: Center) {
        switch center {
        case .workspace:
            workspace.post(name)
        case .distributed:
            distributed.post(name)
        }
    }

    @Test(arguments: reasons)
    func pausesAndResumesThePairedReason(reason: ClipboardMonitor.PauseReason) {
        let pair = Self.pair(for: reason)
        let observer = makeObserver()
        observer.start()
        monitor.start()
        defer { monitor.stop() }

        post(pair.away, to: pair.center)
        #expect(monitor.pauseReasons == [reason])
        #expect(!monitor.isPolling)

        post(pair.back, to: pair.center)
        #expect(monitor.pauseReasons.isEmpty)
        #expect(monitor.isPolling)
    }

    @Test(arguments: reasons)
    func tellsWhenTheUserLeaves(reason: ClipboardMonitor.PauseReason) {
        let pair = Self.pair(for: reason)
        let observer = makeObserver()
        let away = CallCounter()
        observer.onUserAway = { away.call() }
        observer.start()

        post(pair.away, to: pair.center)
        #expect(away.count == 1)
        post(pair.back, to: pair.center)
        #expect(away.count == 1)
    }

    @Test func startTwiceObservesOnce() {
        let observer = makeObserver()
        observer.start()
        observer.start()
        #expect(workspace.observedNames.count == 6)
        #expect(distributed.observedNames.count == 2)
    }

    @Test func reconcileClearsAStaleScreenLock() {
        let observer = makeObserver()
        observer.start()
        monitor.start()
        defer { monitor.stop() }
        distributed.post(SystemActivityObserver.screenIsLockedNotification)

        // The unlock notification was missed, but the window server says the screen is locked.
        session.isScreenLocked = true
        observer.reconcile()
        #expect(monitor.pauseReasons == [.screenLocked])

        session.isScreenLocked = false
        observer.reconcile()
        #expect(monitor.pauseReasons.isEmpty)
        #expect(monitor.isPolling)
    }

    @Test func reconcileClearsAStaleInactiveSession() {
        let observer = makeObserver()
        observer.start()
        monitor.start()
        defer { monitor.stop() }
        workspace.post(NSWorkspace.sessionDidResignActiveNotification)

        session.isActive = false
        observer.reconcile()
        #expect(monitor.pauseReasons == [.sessionInactive])

        session.isActive = true
        observer.reconcile()
        #expect(monitor.pauseReasons.isEmpty)
    }

    @Test(arguments: [
        NSWorkspace.didWakeNotification,
        NSWorkspace.screensDidWakeNotification,
        NSWorkspace.sessionDidBecomeActiveNotification,
    ])
    func wakeClearsAScreenLockWhoseUnlockWasMissed(wake: Notification.Name) {
        let observer = makeObserver()
        observer.start()
        monitor.start()
        defer { monitor.stop() }
        session.isScreenLocked = true
        distributed.post(SystemActivityObserver.screenIsLockedNotification)

        session.isScreenLocked = false
        workspace.post(wake)
        #expect(monitor.pauseReasons.isEmpty)
        #expect(monitor.isPolling)
    }

    @Test func wakeKeepsTheScreenLockWhileTheScreenIsStillLocked() {
        let observer = makeObserver()
        observer.start()
        monitor.start()
        defer { monitor.stop() }
        session.isScreenLocked = true
        distributed.post(SystemActivityObserver.screenIsLockedNotification)
        workspace.post(NSWorkspace.willSleepNotification)

        workspace.post(NSWorkspace.didWakeNotification)
        #expect(monitor.pauseReasons == [.screenLocked])
        #expect(!monitor.isPolling)
    }
}

@MainActor
struct ClipboardMonitorUserIsActiveTests {
    @Test func userActivityClearsEveryPauseReason() {
        let monitor = ClipboardMonitor(
            pasteboard: FakePasteboard(),
            history: ClipboardHistory(),
            frontmostApp: { nil },
            activity: CountingActivity()
        )
        monitor.start()
        defer { monitor.stop() }
        monitor.pause(for: .screenLocked)
        monitor.pause(for: .displaySleep)
        monitor.pause(for: .sessionInactive)
        monitor.pause(for: .systemSleep)

        monitor.userIsActive()
        #expect(monitor.pauseReasons.isEmpty)
        #expect(monitor.isPolling)
    }

    @Test func userActivityCreditsTheNextFoundCopyToNoApp() throws {
        let pasteboard = FakePasteboard()
        let history = ClipboardHistory()
        let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            history: history,
            frontmostApp: { notes },
            activity: CountingActivity()
        )
        monitor.start()
        defer { monitor.stop() }
        monitor.pause(for: .screenLocked)
        pasteboard.copy("copied while locked")

        monitor.userIsActive()
        let entry = try #require(history.entries.first)
        #expect(entry.sourceApp == nil)
    }
}

@MainActor
struct NotificationCenterObserverTests {
    @Test func callsHandlerUntilRemoved() {
        let center = NotificationCenter()
        let observer = NotificationCenterObserver(center: center, queue: nil)
        let name = Notification.Name("test")
        let calls = CallCounter()
        observer.observe(name) { calls.call() }

        center.post(name: name, object: nil)
        #expect(calls.count == 1)

        observer.removeAllObservers()
        center.post(name: name, object: nil)
        #expect(calls.count == 1)
    }
}
