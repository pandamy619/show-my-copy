import Foundation
import Testing

@testable import ShowMyCopy

/// What the app wrote itself and left on the clipboard when it quit, found at the next launch or on the first look
/// after a pause that began before the monitor had looked (a launch while the Mac sleeps or the screen is locked):
/// - Text that no entry holds, such as a folder copied from the preview, is not recorded, and it is skipped by its
///   `PasteboardMarker.unrecorded` marker before anything else is read.
/// - An entry copied back is in the history, so it is made current again, keeping its date and source app.
/// - A copy from another app is recorded as before, also one that carries another app's source marker.
@MainActor
struct ClipboardMonitorOwnWriteTests {
    private let pasteboard = FakePasteboard()
    private let history = InMemoryHistoryStore()
    private let environment = MonitorEnvironment()
    private let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")
    private let safari = SourceApp(bundleIdentifier: "com.apple.Safari", name: "Safari")

    /// A first look right after launch (nil), or after a pause that began before the monitor looked at all.
    nonisolated static let firstLooks: [PollingSchedule.PauseReason?] = [nil, .systemSleep, .screenLocked]

    /// The last session: "newest" and "older", copied in Notes, are in the history, and the monitor has seen them.
    private func runLastSession() -> (monitor: ClipboardMonitor, copier: EntryCopier) {
        environment.frontmostApp = notes
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        // Its first look found nothing, so the copies after it are known to come from the app in front.
        monitor.poll()
        pasteboard.copy("older")
        monitor.poll()
        environment.now += 1
        pasteboard.copy("newest")
        monitor.poll()
        let copier = EntryCopier(
            history: history, pasteboard: pasteboard, monitor: monitor, now: { [environment] in environment.now })
        // The user works in Safari with the history window open.
        environment.frontmostApp = safari
        environment.now += 60
        return (monitor, copier)
    }

    /// The app quit and starts again: the history is loaded with no entry current yet, and a new monitor takes its
    /// first look, after `pause` if one is given.
    private func relaunch(pausedFor pause: PollingSchedule.PauseReason?) {
        history.markCurrentSkipped()
        environment.now += 3600
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        if let pause {
            monitor.pause(for: pause)
            monitor.resume(for: pause)
        }
        monitor.poll()
    }

    @Test(arguments: firstLooks)
    func aFolderCopiedFromThePreviewIsNotRecordedAtTheNextLaunch(pausedFor pause: PollingSchedule.PauseReason?) {
        let (_, copier) = runLastSession()
        copier.copyText("~/Documents")
        let before = history.entries
        let textReads = pasteboard.stringReadCount
        let dataReads = pasteboard.dataReadCount

        relaunch(pausedFor: pause)

        #expect(history.entries == before)
        #expect(history.currentEntryID == nil)
        // Skipped by its marker alone: the text itself is not read.
        #expect(pasteboard.stringReadCount == textReads)
        #expect(pasteboard.dataReadCount == dataReads)
    }

    @Test func theAddressCopiedInSettingsIsNotRecordedAtTheNextLaunch() {
        let (_, copier) = runLastSession()
        copier.copyText("https://github.com/pandamy619/show-my-copy")

        relaunch(pausedFor: nil)

        #expect(history.entries.map(\.text) == ["newest", "older"])
    }

    @Test func aCopyMadeAfterTheSkippedFolderIsRecorded() throws {
        let (_, copier) = runLastSession()
        copier.copyText("~/Documents")
        relaunch(pausedFor: nil)

        pasteboard.copy("fresh")
        environment.makeMonitor(pasteboard: pasteboard, history: history).poll()

        #expect(try #require(history.entries.first).text == "fresh")
    }

    @Test(arguments: firstLooks)
    func anEntryCopiedBackIsCurrentAgainAtTheNextLaunch(pausedFor pause: PollingSchedule.PauseReason?) throws {
        let (_, copier) = runLastSession()
        let older = try #require(history.entries.first { $0.text == "older" })
        copier.copy(older)
        let copiedBack = try #require(history.entries.first)

        relaunch(pausedFor: pause)

        // It still holds what the clipboard holds, with the date and source app it got when it was copied back.
        #expect(history.entries.first == copiedBack)
        #expect(history.entries.map(\.text) == ["older", "newest"])
        #expect(history.currentEntryID == copiedBack.id)
        #expect(copiedBack.sourceApp == notes)
    }

    @Test(arguments: firstLooks)
    func aConcealedEntryCopiedBackIsCurrentAgainWithItsExpiry(pausedFor pause: PollingSchedule.PauseReason?) throws {
        environment.savePasswords(for: 86_400)
        let (monitor, copier) = runLastSession()
        pasteboard.copy("hunter2", markers: [PasteboardMarker.concealed])
        monitor.poll()
        let password = try #require(history.entries.first)
        pasteboard.copy("after")
        monitor.poll()
        copier.copy(password)
        let copiedBack = try #require(history.entries.first)

        relaunch(pausedFor: pause)

        #expect(history.entries.first == copiedBack)
        #expect(copiedBack.isConcealed)
        #expect(copiedBack.expiresAt == password.expiresAt)
        #expect(history.currentEntryID == copiedBack.id)
    }

    @Test(arguments: firstLooks)
    func aCopyFromAnotherAppIsRecordedAtTheNextLaunch(pausedFor pause: PollingSchedule.PauseReason?) throws {
        _ = runLastSession()
        pasteboard.copy("copied while the app was not running")

        relaunch(pausedFor: pause)

        let entry = try #require(history.entries.first)
        #expect(entry.text == "copied while the app was not running")
        // Copied before launch or during the pause: not necessarily in the app in front now.
        #expect(entry.sourceApp == nil)
        #expect(history.currentEntryID == entry.id)
    }

    @Test(arguments: firstLooks)
    func aCopyWithAnotherAppsSourceMarkerIsRecordedAtTheNextLaunch(
        pausedFor pause: PollingSchedule.PauseReason?
    ) throws {
        _ = runLastSession()
        // Apps that follow nspasteboard.org write the source marker too, with their own bundle identifier.
        pasteboard.copy("from another clipboard tool", markers: [PasteboardMarker.source])

        relaunch(pausedFor: pause)

        let entry = try #require(history.entries.first)
        #expect(entry.text == "from another clipboard tool")
        #expect(history.currentEntryID == entry.id)
    }

    @Test(arguments: [PollingSchedule.PauseReason.systemSleep, .screenLocked])
    func aFolderCopiedBeforeAPauseIsNotRecordedAfterIt(reason: PollingSchedule.PauseReason) {
        let (monitor, copier) = runLastSession()
        copier.copyText("~/Documents")
        let before = history.entries

        monitor.pause(for: reason)
        monitor.resume(for: reason)
        monitor.poll()

        #expect(history.entries == before)
        #expect(history.currentEntryID == nil)
    }

    @Test(arguments: [PollingSchedule.PauseReason.systemSleep, .screenLocked])
    func aFolderTheMonitorWasNotToldAboutIsNotRecordedAfterAPause(reason: PollingSchedule.PauseReason) {
        let (monitor, _) = runLastSession()
        let before = history.entries
        monitor.pause(for: reason)
        // Written while the monitor was away without telling it, as only another copy of the app could.
        pasteboard.writeUnrecorded("~/Documents")
        let textReads = pasteboard.stringReadCount

        monitor.resume(for: reason)
        monitor.poll()

        #expect(history.entries == before)
        #expect(history.currentEntryID == nil)
        #expect(pasteboard.stringReadCount == textReads)
    }
}
