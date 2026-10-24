import Foundation

/// Puts an entry the user picked in the history window back on the pasteboard.
@MainActor
final class EntryCopier: EntryCopying {
    private let history: any HistoryStore
    private let pasteboard: any PasteboardWriting
    private let monitor: any PasteboardChangeTracking
    /// Where image data is read from. Without it images cannot be copied back.
    private let blobs: (any BlobStore)?
    private let now: @MainActor () -> Date

    init(
        history: any HistoryStore,
        pasteboard: any PasteboardWriting,
        monitor: any PasteboardChangeTracking,
        blobs: (any BlobStore)? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.history = history
        self.pasteboard = pasteboard
        self.monitor = monitor
        self.blobs = blobs
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
        guard let payload = payload(for: entry.content) else {
            return false
        }
        guard let changeCount = pasteboard.write(payload, concealed: entry.isConcealed) else {
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

    /// What to put on the pasteboard for `content`: styled text with its plain text, an image in its original
    /// format (read from the blob store now, the only time the full image is read), files as their URLs. Nil when
    /// the image data cannot be read.
    private func payload(for content: ClipboardContent) -> PasteboardPayload? {
        switch content {
        case .text(let text):
            return .text(text)
        case .richText(let rtf, let plain):
            return .richText(rtf: rtf, plain: plain)
        case .image(let image):
            guard let blobs else {
                AppLogger.clipboard.error("Cannot copy an image without its saved data")
                return nil
            }
            do {
                return .image(try blobs.read(image.blobID), typeIdentifier: image.typeIdentifier)
            } catch {
                AppLogger.clipboard.error("Could not read the saved image to copy it")
                return nil
            }
        case .files(let files):
            return .files(files.map(\.url))
        }
    }
}
