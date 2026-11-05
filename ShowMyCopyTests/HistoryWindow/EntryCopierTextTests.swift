import Foundation
import Testing

@testable import ShowMyCopy

/// Text the user selects in the history window and copies with ⌘C, such as the folder of a copied file.
@MainActor
struct EntryCopierTextTests {
    private let pasteboard = FakePasteboard()
    private let history = InMemoryHistoryStore()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let finder = SourceApp(bundleIdentifier: "com.apple.finder", name: "Finder")

    private func makeMonitor() -> ClipboardMonitor {
        // The history panel does not activate the app, so the app in front stays the one the user copied from.
        MonitorFactory.make(pasteboard: pasteboard, history: history, frontmostApp: { [finder] in finder })
    }

    @Test func copiedTextIsWrittenAsPlainText() {
        let monitor = makeMonitor()
        monitor.poll()

        let changeCount = EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor)
            .copyText("~/Documents")

        #expect(changeCount == pasteboard.changeCount)
        #expect(pasteboard.writtenPayloads == [.text("~/Documents")])
        #expect(pasteboard.writtenConcealed == [false])
    }

    @Test func copiedTextIsNotRecorded() {
        history.record(text: "older", sourceApp: finder, at: start)
        let monitor = makeMonitor()
        monitor.poll()

        EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor).copyText("~/Documents")
        monitor.poll()

        #expect(history.entries.map(\.text) == ["older"])
    }

    @Test func noEntryIsCurrentAfterwards() throws {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copy("older")
        monitor.poll()
        #expect(history.currentEntryID != nil)

        EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor).copyText("~/Documents")

        // The clipboard holds the folder now, which no entry holds.
        #expect(history.currentEntryID == nil)
    }

    @Test func copyMadeJustBeforeIsRecordedFirst() {
        let monitor = makeMonitor()
        monitor.poll()

        pasteboard.copy("copied between polls")
        EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor).copyText("~/Documents")
        monitor.poll()

        #expect(history.entries.map(\.text) == ["copied between polls"])
    }

    @Test func copiesAfterwardsAreRecorded() {
        let monitor = makeMonitor()
        monitor.poll()

        EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor).copyText("~/Documents")
        pasteboard.copy("fresh")
        monitor.poll()

        #expect(history.entries.map(\.text) == ["fresh"])
    }

    @Test func failedWriteLeavesHistoryAndMonitorAlone() throws {
        history.record(text: "older", sourceApp: finder, at: start)
        let monitor = makeMonitor()
        monitor.poll()
        let currentID = history.currentEntryID
        pasteboard.writeFails = true

        let copied = EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor).copyText("~/Documents")

        #expect(copied == nil)
        #expect(history.currentEntryID == currentID)
        pasteboard.copy("fresh")
        monitor.poll()
        #expect(history.entries.map(\.text) == ["fresh", "older"])
    }

    @Test func emptySelectionWritesNothing() {
        let monitor = makeMonitor()
        monitor.poll()

        #expect(EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor).copyText("") == nil)
        #expect(pasteboard.writtenPayloads.isEmpty)
    }
}
