import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct ClipboardMonitorClearedClipboardTests {
    private let pasteboard = FakePasteboard()
    private let history = InMemoryHistoryStore()
    private let environment = MonitorEnvironment()
    private let safari = SourceApp(bundleIdentifier: "com.apple.Safari", name: "Safari")

    /// Records "older" and then "hunter2", copied without a marker from a browser extension.
    private func makeMonitorWithUnmarkedPassword() -> ClipboardMonitor {
        environment.frontmostApp = safari
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        pasteboard.copy("older")
        monitor.poll()
        pasteboard.copy("hunter2")
        monitor.poll()
        return monitor
    }

    /// The pasteboard is emptied and the next poll finds it still empty.
    private func clearAndConfirm(_ monitor: ClipboardMonitor) {
        pasteboard.clear()
        monitor.poll()
        monitor.poll()
    }

    @Test func clipboardClearedSoonAfterACopyRemovesTheEntry() {
        let monitor = makeMonitorWithUnmarkedPassword()
        environment.now += 90
        clearAndConfirm(monitor)

        #expect(history.entries.map(\.text) == ["older"])
        #expect(history.currentEntryID == nil)
    }

    @Test func clearCountsOnlyWhenTheNextPollStillFindsTheClipboardEmpty() {
        let monitor = makeMonitorWithUnmarkedPassword()
        pasteboard.clear()
        monitor.poll()
        #expect(history.entries.map(\.text) == ["hunter2", "older"])
        #expect(history.currentEntryID == nil)

        monitor.poll()
        #expect(history.entries.map(\.text) == ["older"])
    }

    @Test func appThatEmptiesTheClipboardBeforeWritingKeepsTheEntry() throws {
        let monitor = makeMonitorWithUnmarkedPassword()
        let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")
        environment.frontmostApp = notes
        // The app empties the pasteboard; a poll lands before it writes, which brings no new change count.
        pasteboard.clear()
        monitor.poll()
        pasteboard.fillWithoutNewChangeCount("written after the clear")
        monitor.poll()

        #expect(history.entries.map(\.text) == ["written after the clear", "hunter2", "older"])
        let top = try #require(history.entries.first)
        #expect(top.sourceApp == notes)
        #expect(history.currentEntryID == top.id)
    }

    @Test func appThatEmptiesTheClipboardAndWritesWithANewChangeKeepsTheEntry() {
        let monitor = makeMonitorWithUnmarkedPassword()
        pasteboard.clear()
        monitor.poll()
        pasteboard.copy("written after the clear")
        monitor.poll()
        monitor.poll()

        #expect(history.entries.map(\.text) == ["written after the clear", "hunter2", "older"])
    }

    @Test func clipboardClearedSoonAfterPinningKeepsThePinnedEntry() throws {
        let history = InMemoryHistoryStore(now: { [environment] in environment.now })
        environment.frontmostApp = safari
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        pasteboard.copy("snippet")
        monitor.poll()
        let id = try #require(history.currentEntryID)
        environment.now += 30
        history.setPinned(true, id: id)
        environment.now += 30

        clearAndConfirm(monitor)

        // The user chose to keep it, and a password is never pinned.
        #expect(history.entries.map(\.id) == [id])
        #expect(history.entries.first?.isPinned == true)
        #expect(history.entries.first?.isConcealed == false)
    }

    @Test func clearedClipboardNeverRemovesFiles() {
        environment.frontmostApp = safari
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        pasteboard.copy("older")
        monitor.poll()
        pasteboard.copyFiles([URL(filePath: "/Users/me/report.pdf")])
        monitor.poll()
        clearAndConfirm(monitor)

        // A password is text: files are not one, so being wrong would only lose them.
        #expect(history.entries.map(\.kind) == [.files, .text])
    }

    @Test func clearedClipboardNeverRemovesFilesWhenPasswordsAreSaved() {
        environment.savePasswords()
        environment.frontmostApp = safari
        let monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        pasteboard.copyFiles([URL(filePath: "/Users/me/report.pdf")])
        monitor.poll()
        clearAndConfirm(monitor)

        #expect(history.entries.map(\.kind) == [.files])
        #expect(history.entries.first?.isConcealed == false)
    }

    @Test func emptyTextCountsAsAClear() {
        let monitor = makeMonitorWithUnmarkedPassword()
        pasteboard.copy("")
        monitor.poll()
        monitor.poll()
        #expect(history.entries.map(\.text) == ["older"])
    }

    @Test func itemWithOnlyMarkersCountsAsAClear() {
        let monitor = makeMonitorWithUnmarkedPassword()
        pasteboard.clear()
        pasteboard.addMarker(PasteboardMarker.concealed)
        monitor.poll()
        monitor.poll()
        #expect(history.entries.map(\.text) == ["older"])
    }

    @Test func clearAtTheEndOfTheWindowStillCounts() {
        let monitor = makeMonitorWithUnmarkedPassword()
        environment.now += ClearedClipboardCheck.window
        clearAndConfirm(monitor)
        #expect(history.entries.map(\.text) == ["older"])
    }

    @Test func clearAfterTheWindowKeepsTheEntry() {
        let monitor = makeMonitorWithUnmarkedPassword()
        environment.now += ClearedClipboardCheck.window + 1
        clearAndConfirm(monitor)

        #expect(history.entries.map(\.text) == ["hunter2", "older"])
        #expect(history.currentEntryID == nil)
    }

    @Test func copyingSomethingElseIsNotAClear() {
        let monitor = makeMonitorWithUnmarkedPassword()
        pasteboard.copy("something else")
        monitor.poll()
        #expect(history.entries.map(\.text) == ["something else", "hunter2", "older"])
    }

    @Test func copyingAnImageIsNotAClear() {
        let monitor = makeMonitorWithUnmarkedPassword()
        pasteboard.copyImage()
        monitor.poll()
        #expect(history.entries.map(\.text) == ["hunter2", "older"])
        #expect(history.currentEntryID == nil)
    }

    @Test func clearAfterASkippedCopyRemovesNothing() {
        let monitor = makeMonitorWithUnmarkedPassword()
        pasteboard.copy("temporary", markers: [PasteboardMarker.transient])
        monitor.poll()
        clearAndConfirm(monitor)
        // The entry was no longer on the clipboard, so whatever was cleared was not it.
        #expect(history.entries.map(\.text) == ["hunter2", "older"])
    }

    @Test func clearConcealsTheEntryWhenPasswordsAreSaved() throws {
        environment.savePasswords(for: 60)
        let monitor = makeMonitorWithUnmarkedPassword()
        environment.now += 90
        clearAndConfirm(monitor)

        let entry = try #require(history.entries.first)
        #expect(entry.text == "hunter2")
        #expect(entry.isConcealed)
        #expect(entry.expiresAt == environment.now + 60)
        #expect(history.currentEntryID == nil)
        #expect(history.entries.last.map(\.isConcealed) == false)
    }
}
