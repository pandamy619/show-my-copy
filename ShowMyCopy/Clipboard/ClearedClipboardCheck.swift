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
///
/// While the monitor is paused (the Mac sleeps or the screen is locked) a password manager can still empty the
/// clipboard, and the monitor sees it only after the pause. When it was emptied is not known then, only that it was
/// after the pause began, so the window is measured to the beginning of the pause, and only when emptying the
/// clipboard was the only change since: otherwise something else was copied meanwhile, and what was emptied is not
/// known to be the entry.
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

    /// When the monitor stopped watching, and the change it had seen last then.
    private struct Pause {
        let changeCount: Int
        let date: Date
    }

    private let history: any HistoryStore
    private var suspect: Suspect?
    /// The last pause, until a look after it finds no change or an emptied clipboard. When the first change after it
    /// is something else, it stays, but then no later change can be the only one since it began.
    private var pause: Pause?

    init(history: any HistoryStore) {
        self.history = history
    }

    /// The monitor stops watching at `date`, for example because the screen is locked; it had seen the pasteboard at
    /// `changeCount` last. Called only when it was watching until then, so the pause began at `date`.
    func monitorPaused(changeCount: Int?, at date: Date) {
        pause = changeCount.map { Pause(changeCount: $0, date: date) }
    }

    /// The monitor looked at the pasteboard while watching and found no change: nothing was emptied during a pause.
    func monitorFoundNoChange() {
        pause = nil
    }

    /// The clipboard was found empty at `changeCount`, at `date`. Nothing is current any more. When the entry that was
    /// current may be a password, the next poll looks again (`isWaiting(at:)`).
    func clipboardWasEmptied(changeCount: Int, at date: Date) {
        defer { history.markCurrentSkipped() }
        suspect = nil
        // Emptied while the monitor was paused, as the only change since: it may have been emptied right after the
        // pause began.
        let emptiedAt = pause.flatMap { $0.changeCount + 1 == changeCount ? $0.date : nil } ?? date
        pause = nil
        guard let currentID = history.currentEntryID,
            let current = history.entries.first(where: { $0.id == currentID }),
            current.content.canBeConcealed,
            emptiedAt.timeIntervalSince(current.date) <= Self.window
        else {
            return
        }
        suspect = Suspect(entryID: currentID, changeCount: changeCount, date: emptiedAt)
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
