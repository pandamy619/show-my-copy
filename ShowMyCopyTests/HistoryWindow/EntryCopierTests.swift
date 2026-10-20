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
