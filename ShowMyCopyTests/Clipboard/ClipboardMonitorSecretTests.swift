import AppKit
import Foundation
import Testing

@testable import ShowMyCopy

/// A clock and password settings the tests change between polls.
@MainActor
final class MonitorEnvironment {
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    var policy = PasswordPolicy.default
    var frontmostApp: SourceApp?

    func makeMonitor(pasteboard: FakePasteboard, history: ClipboardHistory) -> ClipboardMonitor {
        MonitorFactory.make(
            pasteboard: pasteboard,
            history: history,
            frontmostApp: { [unowned self] in frontmostApp },
            now: { [unowned self] in now },
            passwordPolicy: { [unowned self] in policy }
        )
    }

    func savePasswords(for lifetime: TimeInterval = 600) {
        policy = PasswordPolicy(savesPasswords: true, lifetime: lifetime)
    }
}

@MainActor
struct ClipboardMonitorSecretTests {
    private let pasteboard = FakePasteboard()
    private let history = ClipboardHistory()
    private let environment = MonitorEnvironment()
    private let onePassword = SourceApp(bundleIdentifier: "com.1password.1password", name: "1Password")
    private let safari = SourceApp(bundleIdentifier: "com.apple.Safari", name: "Safari")

    /// A monitor that has already seen the pasteboard once, so the next copy has a known source app.
    private func makeWatchingMonitor(frontmostApp: SourceApp?) -> ClipboardMonitor {
        environment.frontmostApp = frontmostApp
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        pasteboard.copy("before")
        monitor.poll()
        return monitor
    }

    @Test(arguments: PasteboardMarker.secret.sorted())
    func markedPasswordIsSkippedWithoutReadingItByDefault(marker: String) {
        let monitor = makeWatchingMonitor(frontmostApp: safari)
        let reads = pasteboard.stringReadCount
        pasteboard.copy("hunter2", markers: [marker])
        monitor.poll()

        #expect(history.entries.map(\.text) == ["before"])
        #expect(history.currentEntryID == nil)
        #expect(pasteboard.stringReadCount == reads)
    }

    @Test func copyFromAPasswordManagerIsSkippedWithoutReadingItByDefault() {
        let monitor = makeWatchingMonitor(frontmostApp: onePassword)
        let reads = pasteboard.stringReadCount
        pasteboard.copy("hunter2")
        monitor.poll()

        #expect(history.entries.map(\.text) == ["before"])
        #expect(history.currentEntryID == nil)
        #expect(pasteboard.stringReadCount == reads)
    }

    @Test(arguments: PasteboardMarker.alwaysSkipped.sorted())
    func transientItemsAreSkippedEvenWhenPasswordsAreSaved(marker: String) {
        environment.savePasswords()
        let monitor = makeWatchingMonitor(frontmostApp: safari)
        pasteboard.copy("temporary", markers: [marker])
        monitor.poll()
        #expect(history.entries.map(\.text) == ["before"])
        #expect(history.currentEntryID == nil)
    }

    @Test(arguments: PasteboardMarker.secret.sorted())
    func markedPasswordIsRecordedConcealedWhenSaved(marker: String) throws {
        environment.savePasswords(for: 60)
        let monitor = makeWatchingMonitor(frontmostApp: safari)
        pasteboard.copy("hunter2", markers: [marker])
        monitor.poll()

        let entry = try #require(history.entries.first)
        #expect(entry.text == "hunter2")
        #expect(entry.isConcealed)
        #expect(entry.expiresAt == environment.now + 60)
        #expect(entry.sourceApp == safari)
        #expect(history.currentEntryID == entry.id)
    }

    @Test func copyFromAPasswordManagerIsRecordedConcealedWhenSaved() throws {
        environment.savePasswords(for: 600)
        let monitor = makeWatchingMonitor(frontmostApp: onePassword)
        pasteboard.copy("hunter2")
        monitor.poll()

        let entry = try #require(history.entries.first)
        #expect(entry.isConcealed)
        #expect(entry.expiresAt == environment.now + 600)
        #expect(entry.sourceApp == onePassword)
    }

    @Test func plainCopyIsNotConcealed() throws {
        environment.savePasswords()
        let monitor = makeWatchingMonitor(frontmostApp: safari)
        pasteboard.copy("hello")
        monitor.poll()
        let entry = try #require(history.entries.first)
        #expect(!entry.isConcealed)
        #expect(entry.expiresAt == nil)
    }

    @Test func markerAddedAfterTheTextConcealsTheEntryWhenSaved() throws {
        environment.savePasswords()
        let monitor = makeWatchingMonitor(frontmostApp: safari)
        pasteboard.copy("hunter2")
        pasteboard.whileReadingString = { $0.addMarker(PasteboardMarker.concealed) }
        monitor.poll()
        #expect(try #require(history.entries.first).isConcealed)
    }

    @Test func firstPollCannotTellThatAPasswordManagerMadeTheCopy() throws {
        // Copied before launch: the app in front now did not necessarily make the copy. Markers still count.
        environment.frontmostApp = onePassword
        pasteboard.copy("copied before launch")
        environment.makeMonitor(pasteboard: pasteboard, history: history).poll()

        let entry = try #require(history.entries.first)
        #expect(!entry.isConcealed)
        #expect(entry.sourceApp == nil)
    }

    @Test func expiredPasswordsAreRemovedOnEveryPoll() {
        environment.savePasswords(for: 60)
        let monitor = makeWatchingMonitor(frontmostApp: onePassword)
        pasteboard.copy("hunter2")
        monitor.poll()

        environment.now += 59
        monitor.poll()
        #expect(history.entries.map(\.text) == ["hunter2", "before"])

        // The pasteboard did not change, but the time is up.
        environment.now += 1
        monitor.poll()
        #expect(history.entries.map(\.text) == ["before"])
        #expect(history.currentEntryID == nil)
    }

    @Test func settingIsReadOnEveryCopy() {
        let monitor = makeWatchingMonitor(frontmostApp: onePassword)
        pasteboard.copy("first")
        monitor.poll()
        #expect(history.entries.map(\.text) == ["before"])

        environment.savePasswords()
        pasteboard.copy("second")
        monitor.poll()
        #expect(history.entries.map(\.text) == ["second", "before"])
    }
}
