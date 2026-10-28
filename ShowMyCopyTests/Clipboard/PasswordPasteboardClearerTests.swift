import Foundation
import Testing

@testable import ShowMyCopy

/// A saved password does not outlive its entry on the clipboard: when it expires or saving passwords is turned off,
/// the clipboard is emptied too, but only while it still holds exactly what the app recorded for that password (the
/// change count the monitor recorded it at), as when the user deletes an entry (`EntryDeleter`).
@MainActor
struct PasswordPasteboardClearerTests {
    private let pasteboard = FakePasteboard()
    private let history = InMemoryHistoryStore()
    private let environment = MonitorEnvironment()

    /// A monitor that saves passwords for a minute and has recorded "before" and then a marked password.
    private func makeMonitorWithPassword() -> ClipboardMonitor {
        environment.savePasswords(for: 60)
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        pasteboard.copy("before")
        monitor.poll()
        pasteboard.copy("hunter2", markers: [PasteboardMarker.concealed])
        monitor.poll()
        return monitor
    }

    @Test func anExpiredPasswordLeavesTheClipboardItIsStillOn() {
        let monitor = makeMonitorWithPassword()
        let passwordChange = pasteboard.changeCount
        environment.now += 59
        monitor.poll()
        #expect(pasteboard.clearedChangeCounts.isEmpty)

        environment.now += 1
        monitor.poll()

        #expect(history.entries.map(\.text) == ["before"])
        #expect(pasteboard.clearedChangeCounts == [passwordChange])
        #expect(pasteboard.text == nil)
        // The app's own clear is not read as a copy or as a password manager clearing a password.
        #expect(monitor.handledChangeCount == pasteboard.changeCount)
        monitor.poll()
        monitor.poll()
        #expect(history.entries.map(\.text) == ["before"])
    }

    @Test func aNewerCopyIsLeftAloneWhenThePasswordExpires() {
        let monitor = makeMonitorWithPassword()
        // Copied after the password, before the monitor looked again.
        pasteboard.copy("newer")
        environment.now += 60

        monitor.poll()

        #expect(pasteboard.clearedChangeCounts.isEmpty)
        #expect(pasteboard.text == "newer")
        #expect(history.entries.map(\.text) == ["newer", "before"])
    }

    @Test func aPasswordThatIsNoLongerCurrentLeavesTheClipboardAlone() {
        let monitor = makeMonitorWithPassword()
        pasteboard.copy("newer")
        monitor.poll()
        environment.now += 60

        monitor.poll()

        #expect(pasteboard.clearedChangeCounts.isEmpty)
        #expect(pasteboard.text == "newer")
    }

    /// Only passwords: an ordinary entry that leaves the history at the age limit stays on the clipboard.
    @Test func anEntryPastTheAgeLimitStaysOnTheClipboard() {
        let history = InMemoryHistoryStore(
            retention: RetentionPolicy(maxAge: .seconds(3600)), now: { [environment] in environment.now })
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        pasteboard.copy("copied")
        monitor.poll()
        environment.now += 3600

        monitor.poll()

        #expect(history.entries.isEmpty)
        #expect(pasteboard.clearedChangeCounts.isEmpty)
        #expect(pasteboard.text == "copied")
    }

    /// The password manager cleared its own copy already; the app never empties what it did not record.
    @Test func aClipboardChangedByAnotherAppIsLeftAlone() {
        let monitor = makeMonitorWithPassword()
        pasteboard.clear()
        environment.now += 60

        monitor.poll()

        #expect(pasteboard.clearedChangeCounts.isEmpty)
        #expect(history.entries.map(\.text) == ["before"])
    }

    @Test func aPasswordCopiedBackFromTheHistoryLeavesTheClipboardWhenItExpires() throws {
        let monitor = makeMonitorWithPassword()
        pasteboard.copy("newer")
        monitor.poll()
        let password = try #require(history.entries.first { $0.isConcealed })
        let copier = EntryCopier(
            history: history, pasteboard: pasteboard, monitor: monitor, now: { [environment] in environment.now })
        #expect(copier.copy(password))
        let copiedChange = pasteboard.changeCount
        #expect(pasteboard.writtenConcealed == [true])

        environment.now += 60
        monitor.poll()

        #expect(history.entries.map(\.text) == ["newer", "before"])
        #expect(pasteboard.clearedChangeCounts == [copiedChange])
        #expect(pasteboard.text == nil)
    }

    @Test func turningSavingPasswordsOffEmptiesTheClipboardThatHoldsOne() throws {
        try TestDefaults.with { defaults in
            let clearer = PasswordPasteboardClearer(history: history, pasteboard: pasteboard)
            let settings = PasswordSettings(
                history: .unsaved(history), defaults: defaults, now: { [environment] in environment.now },
                pasteboardClearer: clearer)
            settings.savesPasswords = true
            let monitor = MonitorFactory.make(
                pasteboard: pasteboard, history: history, now: { [environment] in environment.now },
                passwordPolicy: { settings.policy })
            clearer.connect(to: monitor)
            pasteboard.copy("hunter2", markers: [PasteboardMarker.concealed])
            monitor.poll()
            let passwordChange = pasteboard.changeCount

            settings.savesPasswords = false

            #expect(history.entries.isEmpty)
            #expect(pasteboard.clearedChangeCounts == [passwordChange])
            #expect(monitor.handledChangeCount == pasteboard.changeCount)
        }
    }

    @Test func turningSavingPasswordsOffLeavesANewerCopyAlone() throws {
        try TestDefaults.with { defaults in
            let clearer = PasswordPasteboardClearer(history: history, pasteboard: pasteboard)
            let settings = PasswordSettings(
                history: .unsaved(history), defaults: defaults, now: { [environment] in environment.now },
                pasteboardClearer: clearer)
            settings.savesPasswords = true
            let monitor = MonitorFactory.make(
                pasteboard: pasteboard, history: history, now: { [environment] in environment.now },
                passwordPolicy: { settings.policy })
            clearer.connect(to: monitor)
            pasteboard.copy("hunter2", markers: [PasteboardMarker.concealed])
            monitor.poll()
            pasteboard.copy("newer")

            settings.savesPasswords = false

            #expect(pasteboard.clearedChangeCounts.isEmpty)
            #expect(pasteboard.text == "newer")
        }
    }
}
