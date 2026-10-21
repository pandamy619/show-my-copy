import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct EntryCopierTests {
    private let pasteboard = FakePasteboard()
    private let history = ClipboardHistory()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")
    private let safari = SourceApp(bundleIdentifier: "com.apple.Safari", name: "Safari")

    private func makeMonitor() -> ClipboardMonitor {
        // The frontmost app while the history window is open is the app the user will paste into.
        ClipboardMonitor(pasteboard: pasteboard, history: history, frontmostApp: { [safari] in safari })
    }

    @Test func copyWritesTextAndMovesEntryToTopKeepingSourceApp() throws {
        history.record(text: "older", sourceApp: notes, at: start)
        history.record(text: "newer", sourceApp: nil, at: start + 1)
        let monitor = makeMonitor()
        monitor.poll()
        let older = try #require(history.entries.last)

        let copier = EntryCopier(
            history: history,
            pasteboard: pasteboard,
            monitor: monitor,
            now: { [start] in start + 5 }
        )
        copier.copy(older)

        #expect(pasteboard.writtenTexts == ["older"])
        #expect(pasteboard.string() == "older")
        #expect(history.entries.map(\.text) == ["older", "newer"])
        let top = try #require(history.entries.first)
        #expect(top.id == older.id)
        #expect(top.sourceApp == notes)
        #expect(top.date == start + 5)
        #expect(history.currentEntryID == older.id)
    }

    @Test func copiedEntryBecomesCurrentAfterASkippedCopy() throws {
        history.record(text: "older", sourceApp: notes, at: start)
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copy("secret", markers: [PasteboardMarker.concealed])
        monitor.poll()
        #expect(history.currentEntryID == nil)
        let older = try #require(history.entries.first)

        EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor).copy(older)
        #expect(history.currentEntryID == older.id)
    }

    @Test func monitorDoesNotRecordTheAppsOwnWrite() throws {
        history.record(text: "older", sourceApp: notes, at: start)
        history.record(text: "newer", sourceApp: nil, at: start + 1)
        let monitor = makeMonitor()
        monitor.poll()
        let older = try #require(history.entries.last)

        EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor).copy(older)
        monitor.poll()

        #expect(history.entries.map(\.text) == ["older", "newer"])
        #expect(history.entries.first?.sourceApp == notes)
    }

    @Test func monitorStillRecordsCopiesAfterTheAppsWrite() throws {
        history.record(text: "older", sourceApp: notes, at: start)
        let monitor = makeMonitor()
        monitor.poll()
        let older = try #require(history.entries.first)

        EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor).copy(older)
        pasteboard.copy("fresh")
        monitor.poll()

        #expect(history.entries.map(\.text) == ["fresh", "older"])
        #expect(history.entries.first?.sourceApp == safari)
    }

    @Test func copyMadeJustBeforePickingIsNotLost() throws {
        history.record(text: "older", sourceApp: notes, at: start)
        let monitor = makeMonitor()
        monitor.poll()
        let older = try #require(history.entries.first)

        // Another app copies something and the user picks an entry before the next poll.
        pasteboard.copy("copied between polls")
        EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor).copy(older)

        #expect(history.entries.map(\.text) == ["older", "copied between polls"])
    }

    @Test func failedWriteLeavesHistoryAndMonitorAlone() throws {
        history.record(text: "older", sourceApp: notes, at: start)
        history.record(text: "newer", sourceApp: nil, at: start + 1)
        let monitor = makeMonitor()
        monitor.poll()
        let older = try #require(history.entries.last)
        pasteboard.writeFails = true
        let currentID = history.currentEntryID

        let copied = EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor).copy(older)

        #expect(!copied)
        #expect(history.entries.map(\.text) == ["newer", "older"])
        #expect(history.currentEntryID == currentID)
        // The monitor was not told about a write, so a copy made next is still recorded.
        pasteboard.copy("fresh")
        monitor.poll()
        #expect(history.entries.map(\.text) == ["fresh", "newer", "older"])
    }

    @Test func plainEntryIsWrittenWithoutTheConcealedMarker() throws {
        history.record(text: "older", sourceApp: notes, at: start)
        let monitor = makeMonitor()
        monitor.poll()
        let older = try #require(history.entries.first)

        EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor).copy(older)
        #expect(pasteboard.writtenConcealed == [false])
    }

    @Test func concealedEntryIsWrittenConcealedAndStaysConcealed() throws {
        let onePassword = SourceApp(bundleIdentifier: "com.1password.1password", name: "1Password")
        history.record(
            text: "hunter2", sourceApp: onePassword, at: start, concealed: true, expiresAt: start + 600)
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard, history: history, frontmostApp: { [safari] in safari }, now: { [start] in start })
        pasteboard.copy("newer")
        monitor.poll()
        let password = try #require(history.entries.last)

        let copier = EntryCopier(
            history: history, pasteboard: pasteboard, monitor: monitor, now: { [start] in start + 5 })
        #expect(copier.copy(password))

        #expect(pasteboard.writtenTexts == ["hunter2"])
        #expect(pasteboard.writtenConcealed == [true])
        let top = try #require(history.entries.first)
        #expect(top.id == password.id)
        #expect(top.isConcealed)
        // Copying a password back does not keep it longer.
        #expect(top.expiresAt == start + 600)
        #expect(top.sourceApp == onePassword)

        // The app's own write is not recorded again.
        monitor.poll()
        #expect(history.entries.map(\.text) == ["hunter2", "newer"])
    }

    @Test func concealedEntryTrimmedByTheCatchUpPollComesBackConcealed() throws {
        let history = ClipboardHistory(limit: 10)
        history.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 600)
        for index in 1..<10 {
            history.record(text: "item \(index)", sourceApp: notes, at: start + Double(index))
        }
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard, history: history, frontmostApp: { [safari] in safari }, now: { [start] in start })
        pasteboard.copy("item 9")
        monitor.poll()
        let password = try #require(history.entries.last)

        pasteboard.copy("copied between polls")
        EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor, now: { [start] in start + 5 })
            .copy(password)

        let top = try #require(history.entries.first)
        #expect(top.text == "hunter2")
        #expect(top.isConcealed)
        #expect(top.expiresAt == start + 600)
    }

    @Test func expiredPasswordIsNotCopied() throws {
        history.record(text: "hunter2", sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard, history: history, frontmostApp: { nil }, now: { [start] in start + 60 })
        let password = try #require(history.entries.first)

        let copier = EntryCopier(
            history: history, pasteboard: pasteboard, monitor: monitor, now: { [start] in start + 60 })
        #expect(!copier.copy(password))
        #expect(pasteboard.writtenTexts.isEmpty)
        #expect(history.entries.isEmpty)
    }

    @Test func successfulCopyReturnsTrue() throws {
        history.record(text: "older", sourceApp: notes, at: start)
        let monitor = makeMonitor()
        monitor.poll()
        let older = try #require(history.entries.first)
        #expect(EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor).copy(older))
    }

    @Test func pollsBeforeWritingAndAcknowledgesTheWrite() throws {
        history.record(text: "older", sourceApp: notes, at: start)
        let older = try #require(history.entries.first)
        let tracker = ChangeTrackerSpy()

        #expect(EntryCopier(history: history, pasteboard: pasteboard, monitor: tracker).copy(older))

        #expect(pasteboard.writtenTexts == ["older"])
        #expect(tracker.calls == [.poll, .acknowledge(changeCount: pasteboard.changeCount)])
    }

    @Test func failedWriteIsNotAcknowledged() throws {
        history.record(text: "older", sourceApp: notes, at: start)
        let older = try #require(history.entries.first)
        let tracker = ChangeTrackerSpy()
        pasteboard.writeFails = true

        #expect(!EntryCopier(history: history, pasteboard: pasteboard, monitor: tracker).copy(older))
        #expect(tracker.calls == [.poll])
    }

    @Test func pickedEntryStaysWhenCatchUpPollFillsTheHistory() throws {
        let history = ClipboardHistory(limit: 10)
        for index in 0..<10 {
            history.record(text: "item \(index)", sourceApp: notes, at: start + Double(index))
        }
        let monitor = ClipboardMonitor(pasteboard: pasteboard, history: history, frontmostApp: { [safari] in safari })
        pasteboard.copy("item 9")
        monitor.poll()
        let oldest = try #require(history.entries.last)
        #expect(oldest.text == "item 0")

        pasteboard.copy("copied between polls")
        EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor).copy(oldest)

        #expect(history.entries.count == 10)
        #expect(history.entries.first?.text == "item 0")
        #expect(history.entries.first?.sourceApp == notes)
        #expect(history.entries.dropFirst().first?.text == "copied between polls")
    }
}

@MainActor
struct ClipboardMonitorAcknowledgeTests {
    @Test func acknowledgedChangeIsNotRecorded() {
        let pasteboard = FakePasteboard()
        let history = ClipboardHistory()
        let monitor = ClipboardMonitor(pasteboard: pasteboard, history: history, frontmostApp: { nil })
        monitor.poll()

        pasteboard.copy("written by the app")
        monitor.acknowledge(changeCount: pasteboard.changeCount)
        monitor.poll()
        #expect(history.entries.isEmpty)

        pasteboard.copy("copied by the user")
        monitor.poll()
        #expect(history.entries.map(\.text) == ["copied by the user"])
    }
}
