import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct ClipboardMonitorKindTests {
    private let pasteboard = FakePasteboard()
    private let history = InMemoryHistoryStore()
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let finder = SourceApp(bundleIdentifier: "com.apple.finder", name: "Finder")

    private func makeMonitor() -> ClipboardMonitor {
        MonitorFactory.make(
            pasteboard: pasteboard, history: history, frontmostApp: { [finder] in finder }, now: { [date] in date })
    }

    @Test func recordsCopiedFiles() throws {
        let monitor = makeMonitor()
        monitor.poll()
        let url = URL(filePath: "/Users/me/a.txt")
        pasteboard.copyFiles([url])
        monitor.poll()

        let entry = try #require(history.entries.first)
        guard case .files(let files) = entry.content else {
            Issue.record("A Finder copy is recorded as files")
            return
        }
        #expect(files.map(\.url) == [url])
        #expect(entry.sourceApp == finder)
        #expect(history.currentEntryID == entry.id)
    }

    @Test func recordsStyledText() throws {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copyRichText("styled", rtf: Data("{\\rtf1 styled}".utf8))
        monitor.poll()
        #expect(history.entries.first?.content == .richText(rtf: Data("{\\rtf1 styled}".utf8), plain: "styled"))
    }

    @Test func imagesAreNotRecordedWithoutSomewhereToStoreThem() {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copy([.png: Data([0x89])])
        monitor.poll()
        #expect(history.entries.isEmpty)
        #expect(history.currentEntryID == nil)
    }
}
