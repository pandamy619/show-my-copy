import Foundation

/// Deletes one entry the user picked in the history window, and empties the pasteboard when it holds that entry.
///
/// The pasteboard is emptied only when that is certain to remove nothing but the deleted entry: the history says the
/// entry is current, and the pasteboard's change count is still the one the monitor recorded it at
/// (`PasteboardChangeTracking.handledChangeCount`), so nothing was copied since. Whatever the app did not record (a
/// skipped password, a copy the monitor has not read yet, an item that changed while it was read) is never emptied.
/// The emptied pasteboard is acknowledged as the app's own change, so the monitor does not read it: it records no
/// entry for it and does not take it for a password manager clearing a password (`ClearedClipboardCheck`).
///
/// The last deleted entry can be brought back with Undo while the history window is open. Its record is deleted
/// from disk at once, but its files (an image's data and thumbnail, thumbnails of copied photos) are held in `blobs`
/// until the window closes or another entry is deleted (`finishDeleting()`): the history's deletion of them is put
/// off, as for work in flight (`InFlightBlobStore`), so Clear History, the limits and the sweep at launch leave them
/// alone meanwhile. Undo gives the entry back to the history (`HistoryStore.restore(_:)`), and whatever no entry uses
/// afterwards is deleted. An image whose data is still being saved cannot come back: its files belong to the work
/// that saves them, which deletes them once it finds the entry gone.
@MainActor
final class EntryDeleter: EntryDeleting {
    /// The last deleted entry, while it can come back.
    private struct Deleted {
        let entry: ClipboardEntry
        /// Holds the entry's blobs, so the history's deletion of them waits. Nil for an entry without blobs.
        let blobs: BlobReservation?
    }

    private let history: any HistoryStore
    private let pasteboard: any PasteboardWriting
    private let monitor: any PasteboardChangeTracking
    /// The blob store the history deletes blobs in. Without it the history keeps no blobs.
    private let blobs: InFlightBlobStore?
    private let now: @MainActor () -> Date
    private var deleted: Deleted?

    init(
        history: any HistoryStore,
        pasteboard: any PasteboardWriting,
        monitor: any PasteboardChangeTracking,
        blobs: InFlightBlobStore?,
        now: @escaping @MainActor () -> Date
    ) {
        self.history = history
        self.pasteboard = pasteboard
        self.monitor = monitor
        self.blobs = blobs
        self.now = now
    }

    var canUndoDelete: Bool {
        deleted != nil
    }

    func delete(_ id: ClipboardEntry.ID) {
        finishDeleting()
        // A copy made since the last poll is recorded first: then it is current, and the pasteboard holding it is
        // left alone.
        monitor.poll()
        guard let entry = history.entries.first(where: { $0.id == id }) else {
            return
        }
        let heldChangeCount = history.currentEntryID == id ? monitor.handledChangeCount : nil
        let held = canComeBack(entry) ? hold(entry) : nil
        history.remove(id: id)
        if let heldChangeCount {
            clearPasteboard(ifChangeCountIs: heldChangeCount)
        }
        if canComeBack(entry) {
            deleted = Deleted(entry: entry, blobs: held)
        }
    }

    @discardableResult
    func undoDelete() -> ClipboardEntry.ID? {
        guard let deleted else {
            return nil
        }
        self.deleted = nil
        // Whatever the entry does not use afterwards goes, also when it does not come back.
        defer { release(deleted.blobs) }
        let entry = deleted.entry
        if entry.isConcealed, let expiresAt = entry.expiresAt, expiresAt <= now() {
            AppLogger.history.info("Did not bring back a deleted password whose time is up")
            return nil
        }
        history.restore([entry])
        // Content copied again meanwhile is in the history already, as another entry.
        return history.entries.first { $0.contentHash == entry.contentHash }?.id
    }

    func finishDeleting() {
        guard let deleted else {
            return
        }
        self.deleted = nil
        release(deleted.blobs)
    }

    /// An image whose data is still being saved cannot come back: its entry stands for work in flight, whose files
    /// are deleted by that work once it finds the entry gone. An entry with blobs needs `blobs` to hold them.
    private func canComeBack(_ entry: ClipboardEntry) -> Bool {
        if entry.content.image?.isSaved == false {
            return false
        }
        return entry.content.blobIDs.isEmpty || blobs != nil
    }

    /// Holds the entry's blobs before the history removes it, so the history's deletion of them is put off.
    private func hold(_ entry: ClipboardEntry) -> BlobReservation? {
        let ids = entry.content.blobIDs
        guard !ids.isEmpty, let blobs else {
            return nil
        }
        let reservation = blobs.reservation()
        reservation.hold(ids)
        return reservation
    }

    /// Ends the hold and deletes the blobs whose deletion was put off and that no entry uses.
    private func release(_ reservation: BlobReservation?) {
        guard let reservation, let blobs else {
            return
        }
        let used = Set(history.entries.flatMap(\.content.blobIDs))
        let unused = reservation.release().filter { !used.contains($0) }
        guard !unused.isEmpty else {
            return
        }
        do {
            try blobs.delete(unused)
        } catch {
            AppLogger.history.error("Could not delete the files of a deleted entry; they go at the next launch")
        }
    }

    private func clearPasteboard(ifChangeCountIs changeCount: Int) {
        guard let cleared = pasteboard.clearContents(ifChangeCountIs: changeCount) else {
            AppLogger.clipboard.debug("The pasteboard changed since the deleted entry was copied; it is left alone")
            return
        }
        monitor.acknowledge(changeCount: cleared)
        AppLogger.clipboard.debug("Emptied the pasteboard, which held the deleted entry")
    }
}
