import Foundation

/// Puts an entry the user picked in the history window back on the pasteboard.
@MainActor
final class EntryCopier {
    private let history: ClipboardHistory
    private let pasteboard: any PasteboardWriting
    private let monitor: ClipboardMonitor
    private let now: @MainActor () -> Date

    init(
        history: ClipboardHistory,
        pasteboard: any PasteboardWriting,
        monitor: ClipboardMonitor,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.history = history
        self.pasteboard = pasteboard
        self.monitor = monitor
        self.now = now
    }

    /// Writes the text to the pasteboard and puts the entry at the top of the history with its original source app.
    ///
    /// The monitor first records anything copied since its last poll, so that copy is not lost. Then it is told
    /// about the write, so the app's own write is not recorded again with the frontmost app as its source.
    /// The entry is recorded by text, so it comes back even if the catch-up poll trimmed it from a full history.
    func copy(_ entry: ClipboardEntry) {
        monitor.poll()
        let changeCount = pasteboard.write(entry.text)
        monitor.acknowledge(changeCount: changeCount)
        history.record(text: entry.text, sourceApp: entry.sourceApp, at: now())
    }
}
