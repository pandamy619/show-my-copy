import Foundation

/// Removes what the history keeps only for a time: passwords whose time is up and, with an age limit, entries past
/// it (`HistoryStore.removeExpired(at:)`).
///
/// `ClipboardMonitor` runs it on every poll, not only when the pasteboard changed, so expired entries leave the
/// history on time while nothing is copied. Polling starts again with a poll right after the Mac wakes or the screen
/// is unlocked, so what expired meanwhile goes then, before the history can be shown.
///
/// A password that leaves the history this way also leaves the pasteboard when it is still exactly what the app
/// recorded there (`PasswordPasteboardClearer`).
@MainActor
final class HistoryExpiry {
    private let history: any HistoryStore
    private let pasteboardClearer: PasswordPasteboardClearer
    private let now: @MainActor () -> Date

    init(
        history: any HistoryStore,
        pasteboardClearer: PasswordPasteboardClearer,
        now: @escaping @MainActor () -> Date
    ) {
        self.history = history
        self.pasteboardClearer = pasteboardClearer
        self.now = now
    }

    func removeExpired() {
        let date = now()
        pasteboardClearer.removePasswords {
            history.removeExpired(at: date)
        }
    }
}
