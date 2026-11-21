import AppKit
import Foundation

/// What reading the clipboard for a QR code found.
enum ClipboardImportOutcome: Equatable, Sendable {
    /// The clipboard holds no image the app reads.
    case noImage
    case noQRCode
    /// A QR code, but not one with accounts.
    case notAnAccount(CodeImport.Failure)
    case imported(CodeImportSummary)
}

/// What an import added, and what it found that could not be added.
struct CodeImportSummary: Equatable, Sendable {
    var added: Int
    var duplicates: Int
    var skipped: [SkippedAccount]
    var batchIndex: Int?
    var batchSize: Int?
    /// Whether the screenshot of the QR code was removed from the history and the clipboard.
    var screenshotRemoved = false
    /// Whether the screenshot was left where it is because the accounts are not saved on disk: until they are, it
    /// is the only copy of their secrets on this Mac.
    var screenshotKeptUnsaved = false

    init(result: CodeAccountStore.AddResult, outcome: CodeImport.Outcome) {
        added = result.added
        duplicates = result.duplicates
        skipped = outcome.skipped
        batchIndex = outcome.batchIndex
        batchSize = outcome.batchSize
    }
}

/// Imports accounts from a QR code the user copied as an image: a screenshot of Google Authenticator's export, or of
/// the QR code a service shows, brought to the Mac with Universal Clipboard or AirDrop.
///
/// The screenshot holds every secret in it, so once its accounts are saved on disk it is deleted from the history
/// and, when nothing was copied since, the clipboard is emptied, like a password that left the history
/// (`PasswordPasteboardClearer`). While the accounts cannot be saved (the Keychain is locked or denied, the file is
/// damaged or newer, the write failed) the screenshot stays: it is then the only copy of the secrets on this Mac, and
/// the accounts in memory are gone when the app quits.
@MainActor
final class ClipboardCodeImporter {
    private let pasteboard: any PasteboardReading & PasteboardWriting
    private let history: any HistoryStore
    private let monitor: any PasteboardChangeTracking
    private let reader: any QRCodeReading
    private let store: CodeAccountStore
    /// The largest image read, as for recording images.
    let maximumBytes: Int

    init(
        pasteboard: any PasteboardReading & PasteboardWriting,
        history: any HistoryStore,
        monitor: any PasteboardChangeTracking,
        reader: any QRCodeReading,
        store: CodeAccountStore,
        maximumBytes: Int = ImageContentReader.defaultMaximumBytes
    ) {
        self.pasteboard = pasteboard
        self.history = history
        self.monitor = monitor
        self.reader = reader
        self.store = store
        self.maximumBytes = maximumBytes
    }

    func importFromClipboardImage() async -> ClipboardImportOutcome {
        // Record the screenshot first, as the monitor would in a moment, so it is the current entry and can be
        // removed as such afterwards.
        monitor.poll()
        let types = Set(pasteboard.types)
        let supported = ImageReference.supportedTypes.map { NSPasteboard.PasteboardType($0) }
        guard let type = supported.first(where: types.contains), let data = pasteboard.data(forType: type),
            !data.isEmpty, data.count <= maximumBytes
        else {
            return .noImage
        }
        let changeCount = pasteboard.changeCount
        let currentEntryID = history.currentEntryID
        let payloads = await reader.payloads(inImageData: data, typeIdentifier: type.rawValue)
        guard !payloads.isEmpty else {
            return .noQRCode
        }
        var outcome = CodeImport.Outcome.nothing
        var failure: CodeImport.Failure?
        for payload in payloads where CodeImport.isAddress(payload) {
            do {
                outcome.merge(try CodeImport.parse(payload))
            } catch {
                failure = failure ?? error
            }
        }
        guard !outcome.accounts.isEmpty || !outcome.skipped.isEmpty else {
            return .notAnAccount(failure ?? .empty)
        }
        let result = await store.add(outcome.accounts)
        var summary = CodeImportSummary(result: result, outcome: outcome)
        // Nothing read from the code is in the list (every account counter-based, say): the screenshot stays too.
        guard result.added + result.duplicates > 0 else {
            return .imported(summary)
        }
        await store.finishSaving()
        guard store.availability == .ready, !store.lastSaveFailed else {
            summary.screenshotKeptUnsaved = true
            return .imported(summary)
        }
        summary.screenshotRemoved = removeScreenshot(entryID: currentEntryID, changeCount: changeCount)
        return .imported(summary)
    }

    /// Deletes the entry that was current when the image was read, when it still is and is an image, and empties
    /// the clipboard when nothing was copied since. Returns whether both the history and the clipboard are rid of it;
    /// an image the history never recorded counts as removed from it, but not one it kept under another entry.
    private func removeScreenshot(entryID: ClipboardEntry.ID?, changeCount: Int) -> Bool {
        var removedFromHistory = true
        let current = history.entries.first { $0.id == entryID && $0.id == history.currentEntryID }
        if let current {
            if case .image = current.content {
                history.remove(id: current.id)
                // Checked afterwards, not assumed: a copy of the same image may be kept, such as a pinned one.
                removedFromHistory = !history.entries.contains {
                    $0.id == current.id || $0.contentHash == current.contentHash
                }
            } else {
                removedFromHistory = false
            }
        }
        // The clipboard has not changed, yet an image entry is current: the screenshot was merged into another entry
        // the history kept while it was read, such as a pinned copy of it. That entry is the user's to delete.
        let kept = history.entries.first { $0.id == history.currentEntryID }
        if pasteboard.changeCount == changeCount, kept?.content.image != nil {
            removedFromHistory = false
        }
        guard let cleared = pasteboard.clearContents(ifChangeCountIs: changeCount) else {
            return false
        }
        monitor.acknowledge(changeCount: cleared)
        history.markCurrentSkipped()
        return removedFromHistory
    }
}
