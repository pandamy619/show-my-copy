import Foundation
import Testing

@testable import ShowMyCopy

/// With an age limit, entries leave the history on time while the app idles: every poll looks for them, also when
/// nothing was copied. Pinned entries stay, passwords go at their own expiry or at the age limit, whichever comes
/// first, and a limit the user changes or turns off applies from the next poll.
@MainActor
struct ClipboardMonitorAgeLimitTests {
    private let pasteboard = FakePasteboard()
    private let environment = MonitorEnvironment()
    private static let eightHours: TimeInterval = 8 * 3600

    /// A history with the limits of someone who never chose, on the environment's clock, starting with `saved`.
    private func makeDefaultHistory(restoring saved: [ClipboardEntry] = []) throws -> InMemoryHistoryStore {
        var retention = RetentionPolicy.default
        try TemporaryFolder.withDefaults { defaults in
            retention = HistorySettings.storedRetention(in: defaults)
        }
        return InMemoryHistoryStore(
            restoring: saved, at: environment.now, retention: retention, now: { [environment] in environment.now })
    }

    @Test func entriesPastTheAgeLimitAreRemovedOnAPollWithoutACopy() {
        let history = InMemoryHistoryStore(
            retention: RetentionPolicy(maxAge: .seconds(3600)), now: { [environment] in environment.now })
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        let start = environment.now
        pasteboard.copy("copied")
        monitor.poll()

        environment.now = start + 3599
        monitor.poll()
        #expect(history.entries.map(\.text) == ["copied"])

        environment.now = start + 3600
        monitor.poll()
        #expect(history.entries.isEmpty)
        #expect(history.currentEntryID == nil)
    }

    @Test func byDefaultAnEntryGoesOnThePollEightHoursAfterItWasCopied() throws {
        let history = try makeDefaultHistory()
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        let start = environment.now
        pasteboard.copy("copied")
        monitor.poll()

        environment.now = start + Self.eightHours - 1
        monitor.poll()
        #expect(history.entries.map(\.text) == ["copied"])

        environment.now = start + Self.eightHours
        monitor.poll()
        #expect(history.entries.isEmpty)
    }

    @Test func pinnedEntriesStayPastTheAgeLimit() throws {
        let start = environment.now
        let pinned = StoreHarness.saved("pinned", at: start - 100 * 86_400, pinned: true)
        let history = try makeDefaultHistory(restoring: [pinned])
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        pasteboard.copy("plain")
        monitor.poll()

        environment.now = start + 30 * 86_400
        monitor.poll()
        #expect(history.entries.map(\.id) == [pinned.id])
    }

    @Test func aPasswordGoesAtItsOwnShorterExpiry() throws {
        let history = try makeDefaultHistory()
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        let start = environment.now
        environment.savePasswords(for: 600)
        pasteboard.copy("plain")
        monitor.poll()
        pasteboard.copy("hunter2", markers: [PasteboardMarker.concealed])
        monitor.poll()
        #expect(history.entries.map(\.text) == ["hunter2", "plain"])

        environment.now = start + 600
        monitor.poll()
        #expect(history.entries.map(\.text) == ["plain"])
    }

    /// The earlier of the two wins, also when the age limit comes first.
    @Test func aPasswordWhoseExpiryIsLaterGoesAtTheAgeLimit() throws {
        let start = environment.now
        let password = StoreHarness.saved(
            "hunter2", at: start, concealed: true, expiresAt: start + 2 * Self.eightHours)
        let history = try makeDefaultHistory(restoring: [password])
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)

        environment.now = start + Self.eightHours - 1
        monitor.poll()
        #expect(history.entries.map(\.id) == [password.id])

        environment.now = start + Self.eightHours
        monitor.poll()
        #expect(history.entries.isEmpty)
    }

    /// A pinned password is still a password: it goes at its own expiry.
    @Test func aPinnedPasswordStillGoesAtItsOwnExpiry() throws {
        let start = environment.now
        var password = StoreHarness.saved("hunter2", at: start, concealed: true, expiresAt: start + 600)
        password.isPinned = true
        let history = try makeDefaultHistory(restoring: [password])
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)

        environment.now = start + 600
        monitor.poll()
        #expect(history.entries.isEmpty)
    }

    @Test func aChangedLimitAppliesFromTheNextPoll() throws {
        try TemporaryFolder.withDefaults { defaults in
            let history = try makeDefaultHistory()
            let settings = HistorySettings(
                history: history, defaults: defaults, now: { [environment] in environment.now })
            let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
            let start = environment.now
            pasteboard.copy("copied")
            monitor.poll()

            settings.apply(.after(.seconds(24 * 3600)), for: .age)
            environment.now = start + Self.eightHours
            monitor.poll()
            #expect(history.entries.map(\.text) == ["copied"])

            settings.apply(.after(.seconds(3600)), for: .age)
            #expect(history.entries.isEmpty)

            pasteboard.copy("again")
            monitor.poll()
            environment.now += 3600 - 1
            monitor.poll()
            #expect(history.entries.map(\.text) == ["again"])
            environment.now += 1
            monitor.poll()
            #expect(history.entries.isEmpty)
        }
    }

    @Test func withTheAgeLimitOffNothingGoesForAge() throws {
        try TemporaryFolder.withDefaults { defaults in
            let history = try makeDefaultHistory()
            let settings = HistorySettings(
                history: history, defaults: defaults, now: { [environment] in environment.now })
            let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
            let start = environment.now
            pasteboard.copy("copied")
            monitor.poll()

            settings.apply(.off, for: .age)
            environment.now = start + 365 * 86_400
            monitor.poll()
            #expect(history.entries.map(\.text) == ["copied"])
            #expect(history.currentEntryID == history.entries.first?.id)
        }
    }
}
