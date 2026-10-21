import Foundation

/// Puts an entry the user picked in the history window back on the pasteboard.
@MainActor
final class EntryCopier {
    private let history: any HistoryStore
    private let pasteboard: any PasteboardWriting
    private let monitor: ClipboardMonitor
    private let now: @MainActor () -> Date

    init(
        history: any HistoryStore,
        pasteboard: any PasteboardWriting,
        monitor: ClipboardMonitor,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.history = history
        self.pasteboard = pasteboard
        self.monitor = monitor
        self.now = now
    }

    /// Writes the content to the pasteboard and puts the entry at the top of the history with its original source app.
    ///
    /// The monitor first records anything copied since its last poll, so that copy is not lost. Then it is told
    /// about the write, so the app's own write is not recorded again with the frontmost app as its source.
    /// The entry is recorded by content, so it comes back even if the catch-up poll trimmed it from a full history.
    ///
    /// A concealed entry is written with the concealed marker, so other clipboard managers skip it, and stays
    /// concealed with its original expiry. A password whose time is up is not copied.
    ///
    /// Returns false when the content did not end up on the pasteboard. Then the history and the monitor are left as
    /// they are: whatever is on the pasteboard now is recorded by the next poll as a normal copy.
    @discardableResult
    func copy(_ entry: ClipboardEntry) -> Bool {
        monitor.poll()
        let date = now()
        if entry.isConcealed, let expiresAt = entry.expiresAt, expiresAt <= date {
            AppLogger.clipboard.info("Did not copy a password whose time in the history is up")
            return false
        }
        let written: Int?
        switch entry.content {
        case .text(let text):
            written = pasteboard.write(text, concealed: entry.isConcealed)
        }
        guard let changeCount = written else {
            AppLogger.clipboard.info("Could not put the picked entry on the pasteboard")
            return false
        }
        monitor.acknowledge(changeCount: changeCount)
        history.record(
            entry.content,
            sourceApp: entry.sourceApp,
            at: date,
            concealed: entry.isConcealed,
            expiresAt: entry.expiresAt
        )
        return true
    }
}
