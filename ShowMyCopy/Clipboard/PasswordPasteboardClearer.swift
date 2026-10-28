import Foundation

/// Empties the pasteboard when a password that leaves the history is still on it, so the password does not outlive
/// its entry there, where any app can read it. Password managers empty the clipboard a while after they copy a
/// password; this does the same when the history's time for a password is up (`HistoryExpiry`) or saving passwords is
/// turned off (`PasswordSettings`), also for a password the user copied back from the history (`EntryCopier`).
///
/// The rule is the one `EntryDeleter` follows: the pasteboard is emptied only when that is certain to remove nothing
/// but the password. The history says the password is current, and the pasteboard's change count is still the one the
/// monitor recorded it at, or wrote it at when it was copied back (`PasteboardChangeTracking.handledChangeCount`), so
/// nothing was copied since. Whatever the app did not record, such as a password it skipped or anything copied since,
/// is never emptied. The emptied pasteboard is acknowledged as the app's own change, so the monitor neither records it
/// nor takes it for a password manager clearing a password (`ClearedClipboardCheck`).
@MainActor
final class PasswordPasteboardClearer {
    private let history: any HistoryStore
    private let pasteboard: any PasteboardWriting
    /// The monitor that knows which change the current entry was recorded at. Weak, because the monitor owns the
    /// expiry that uses this. Until it is connected nothing is emptied.
    private weak var tracking: (any PasteboardChangeTracking)?

    init(history: any HistoryStore, pasteboard: any PasteboardWriting) {
        self.history = history
        self.pasteboard = pasteboard
    }

    /// Connects the monitor, once it exists: the monitor itself expires passwords through this.
    func connect(to tracking: any PasteboardChangeTracking) {
        self.tracking = tracking
    }

    /// Runs `removal`, which removes passwords from the history, and empties the pasteboard afterwards when it held
    /// one of them: the current entry was a password before `removal`, is gone after it, and nothing was copied since
    /// the monitor recorded it.
    func removePasswords(_ removal: () -> Void) {
        let held = heldPassword()
        removal()
        guard let held, !history.entries.contains(where: { $0.id == held.id }) else {
            return
        }
        guard let cleared = pasteboard.clearContents(ifChangeCountIs: held.changeCount) else {
            AppLogger.clipboard.debug("The pasteboard changed since the removed password was copied; left alone")
            return
        }
        tracking?.acknowledge(changeCount: cleared)
        AppLogger.clipboard.debug("Emptied the pasteboard, which held a password that left the history")
    }

    /// The current entry when it is a password, with the change count the monitor recorded it at.
    private func heldPassword() -> (id: ClipboardEntry.ID, changeCount: Int)? {
        guard let tracking, let changeCount = tracking.handledChangeCount, let id = history.currentEntryID,
            history.entries.contains(where: { $0.id == id && $0.isConcealed })
        else {
            return nil
        }
        return (id, changeCount)
    }
}
