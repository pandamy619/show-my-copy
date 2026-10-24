import Foundation

/// Recognizes a password copied without a marker, for example from a browser extension, by what password managers
/// do with it: they empty the clipboard a while after the copy. When the clipboard is emptied soon after a copy whose
/// entry is still on it, that entry is most likely such a password: it is hidden with an expiry, or removed when
/// passwords are not saved.
///
/// Being wrong hides or deletes an ordinary entry, so the check acts only where that is unlikely:
/// - Only text can be such a password. Images and files are never touched.
/// - Only within `window` of the copy.
/// - Only when the clipboard is still empty at the next poll, with no new change. Many apps empty the clipboard and
///   write to it a moment later, some without a new change count; a poll can land in between.
@MainActor
final class ClearedClipboardCheck {
    /// How soon after a copy an emptied clipboard counts as a password manager clearing the password it copied.
    /// 1Password and Bitwarden clear after about 90 seconds by default.
    nonisolated static let window: TimeInterval = 180

    /// The entry that may be a password, from the poll that found the clipboard empty.
    private struct Suspect {
        let entryID: ClipboardEntry.ID
        let changeCount: Int
        let date: Date
    }

    private let history: any HistoryStore
    private var suspect: Suspect?

    init(history: any HistoryStore) {
        self.history = history
    }

    /// The clipboard was found empty at `changeCount`. Nothing is current any more. When the entry that was current
    /// may be a password, the next poll looks again (`isWaiting(at:)`).
    func clipboardWasEmptied(changeCount: Int, at date: Date) {
        defer { history.markCurrentSkipped() }
        suspect = nil
        guard let currentID = history.currentEntryID,
            let current = history.entries.first(where: { $0.id == currentID }),
            current.content.canBeConcealed,
            date.timeIntervalSince(current.date) <= Self.window
        else {
            return
        }
        suspect = Suspect(entryID: currentID, changeCount: changeCount, date: date)
    }

    /// Whether the clipboard was found empty at `changeCount` and the next look decides what that meant.
    func isWaiting(at changeCount: Int) -> Bool {
        suspect?.changeCount == changeCount
    }

    /// The next poll found the clipboard still empty, with no new change: the entry is taken for a password.
    func confirm(policy: PasswordPolicy) {
        guard let suspect else {
            return
        }
        self.suspect = nil
        if policy.savesPasswords {
            history.conceal(id: suspect.entryID, expiresAt: suspect.date + policy.lifetime)
            AppLogger.clipboard.debug("The clipboard stayed empty soon after a copy; the entry is now concealed")
        } else {
            history.remove(id: suspect.entryID)
            AppLogger.clipboard.debug("The clipboard stayed empty soon after a copy; the entry was removed")
        }
    }

    /// Something was written to the clipboard after it was emptied: it was not a password manager clearing it.
    func dismiss() {
        suspect = nil
    }
}
