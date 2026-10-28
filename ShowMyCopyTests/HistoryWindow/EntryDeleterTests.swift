import Foundation
import Testing

@testable import ShowMyCopy

/// Deleting an entry empties the pasteboard only when it surely holds that entry and nothing newer, and the
/// monitor does not take the emptied pasteboard for a copy or for a password manager clearing a password.
@MainActor
struct EntryDeleterTests {
    private let pasteboard = FakePasteboard()
    private let history = ClipboardHistory()
    private let environment = MonitorEnvironment()
    private let monitor: ClipboardMonitor
    private let deleter: EntryDeleter

    init() {
        monitor = environment.makeMonitor(pasteboard: pasteboard, history: history)
        deleter = EntryDeleter(
            history: history, pasteboard: pasteboard, monitor: monitor, blobs: nil,
            now: { [environment] in environment.now })
    }

    /// Another app copies `text` and the monitor records it.
    @discardableResult
    private func copy(_ text: String, markers: [String] = []) throws -> ClipboardEntry.ID {
        pasteboard.copy(text, markers: markers)
        monitor.poll()
        return try #require(history.currentEntryID)
    }

    /// Polls as the timer would, and checks that the pasteboard was not read.
    private func expectNextPollsReadNothing(sourceLocation: SourceLocation = #_sourceLocation) {
        let reads = (pasteboard.stringReadCount, pasteboard.dataReadCount)
        monitor.poll()
        monitor.poll()
        #expect(pasteboard.stringReadCount == reads.0, sourceLocation: sourceLocation)
        #expect(pasteboard.dataReadCount == reads.1, sourceLocation: sourceLocation)
    }

    // MARK: - The current entry

    @Test func deletingTheCurrentEntryEmptiesThePasteboard() throws {
        try copy("older")
        let current = try copy("on the clipboard")

        deleter.delete(current)

        #expect(history.entries.map(\.text) == ["older"])
        #expect(history.currentEntryID == nil)
        #expect(pasteboard.clearedChangeCounts == [2])
        #expect(pasteboard.text == nil)
    }

    @Test func theEmptiedPasteboardIsNotRecordedOrRead() throws {
        try copy("older")
        let current = try copy("on the clipboard")

        deleter.delete(current)
        expectNextPollsReadNothing()

        #expect(history.entries.map(\.text) == ["older"])
        #expect(history.currentEntryID == nil)
    }

    /// The monitor is told the emptied pasteboard is the app's own change, so it never reads it as a copy or as a
    /// password manager clearing a password.
    @Test func theClearIsAcknowledgedAsTheAppsOwnChange() throws {
        let tracker = ChangeTrackerSpy()
        let deleter = EntryDeleter(
            history: history, pasteboard: pasteboard, monitor: tracker, blobs: nil,
            now: { [environment] in environment.now })
        pasteboard.copy("on the clipboard")
        let id = history.record(text: "on the clipboard", sourceApp: nil, at: environment.now)
        tracker.handledChangeCount = pasteboard.changeCount

        deleter.delete(id)

        #expect(pasteboard.clearedChangeCounts == [1])
        #expect(tracker.calls == [.poll, .acknowledge(changeCount: 2)])
    }

    @Test func deletingAnotherEntryLeavesThePasteboardAlone() throws {
        let older = try copy("older")
        try copy("on the clipboard")

        deleter.delete(older)

        #expect(history.entries.map(\.text) == ["on the clipboard"])
        #expect(pasteboard.clearedChangeCounts.isEmpty)
        #expect(pasteboard.text == "on the clipboard")
    }

    @Test func anEntryCopiedBackByTheAppIsEmptiedToo() throws {
        let older = try copy("older")
        try copy("newer")
        let copier = EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor)
        let entry = try #require(history.entries.first { $0.id == older })
        #expect(copier.copy(entry))

        deleter.delete(older)

        #expect(pasteboard.text == nil)
        expectNextPollsReadNothing()
        #expect(history.entries.map(\.text) == ["newer"])
    }

    // MARK: - Something newer was copied

    @Test func aCopyTheMonitorHasNotReadYetIsRecordedAndKept() throws {
        let deleted = try copy("deleted")
        // Copied, and the entry deleted before the next poll.
        pasteboard.copy("copied since")

        deleter.delete(deleted)

        #expect(history.entries.map(\.text) == ["copied since"])
        #expect(history.currentEntryID == history.entries.first?.id)
        #expect(pasteboard.clearedChangeCounts.isEmpty)
        #expect(pasteboard.text == "copied since")
    }

    @Test func aPasswordThatWasNotRecordedIsNotEmptied() throws {
        let deleted = try copy("deleted")
        pasteboard.copy("hunter2", markers: [PasteboardMarker.concealed])
        monitor.poll()
        #expect(history.currentEntryID == nil)

        deleter.delete(deleted)

        #expect(history.entries.isEmpty)
        #expect(pasteboard.clearedChangeCounts.isEmpty)
        #expect(pasteboard.text == "hunter2")
    }

    @Test func aCopyThatChangesWhileTheMonitorReadsItIsNotEmptied() throws {
        let deleted = try copy("deleted")
        pasteboard.copy("first")
        // Another app replaces the item while the catch-up poll reads it: the poll records nothing.
        pasteboard.whileReadingString = { $0.copy("second") }

        deleter.delete(deleted)

        #expect(history.entries.isEmpty)
        #expect(pasteboard.clearedChangeCounts.isEmpty)
        #expect(pasteboard.text == "second")
        monitor.poll()
        #expect(history.entries.map(\.text) == ["second"])
    }

    @Test func aCopyMadeAfterTheDeletionIsRecorded() throws {
        try copy("older")
        let deleted = try copy("deleted")
        deleter.delete(deleted)

        try copy("copied after")

        #expect(history.entries.map(\.text) == ["copied after", "older"])
        #expect(pasteboard.text == "copied after")
    }

    @Test func nothingIsEmptiedBeforeTheMonitorHasSeenThePasteboard() throws {
        let id = history.record(text: "saved before", sourceApp: nil, at: environment.now)
        let idle = ChangeTrackerSpy()
        let deleter = EntryDeleter(
            history: history, pasteboard: pasteboard, monitor: idle, blobs: nil,
            now: { [environment] in environment.now })
        pasteboard.copy("saved before")

        deleter.delete(id)

        #expect(idle.calls == [.poll])
        #expect(pasteboard.clearedChangeCounts.isEmpty)
    }

    // MARK: - Passwords

    @Test func deletingASavedPasswordEmptiesThePasteboard() throws {
        environment.savePasswords()
        try copy("older")
        let password = try copy("hunter2", markers: [PasteboardMarker.concealed])
        #expect(history.entries.first?.isConcealed == true)

        deleter.delete(password)

        #expect(history.entries.map(\.text) == ["older"])
        #expect(pasteboard.text == nil)
        expectNextPollsReadNothing()
    }

    /// An unmarked password that a password manager would clear a moment later: the app's own clear is not taken
    /// for it, so the entry before it is neither hidden nor removed.
    @Test func theClearedClipboardCheckDoesNotFireOnTheAppsOwnClear() throws {
        try copy("older")
        let unmarked = try copy("hunter2")
        environment.now += 30

        deleter.delete(unmarked)
        environment.now += 1
        monitor.poll()
        monitor.poll()

        #expect(history.entries.map(\.text) == ["older"])
        #expect(history.entries.allSatisfy { !$0.isConcealed })
        // A password manager clearing the clipboard later is not mistaken for anything either.
        let next = try copy("next")
        pasteboard.clear()
        monitor.poll()
        monitor.poll()
        #expect(history.entries.map(\.text) == ["older"])
        #expect(!history.entries.contains { $0.id == next })
    }

    @Test func deletingAnUnknownEntryChangesNothing() throws {
        try copy("on the clipboard")

        deleter.delete(UUID())

        #expect(history.entries.map(\.text) == ["on the clipboard"])
        #expect(pasteboard.clearedChangeCounts.isEmpty)
        #expect(!deleter.canUndoDelete)
    }
}
