import Foundation

/// Removes passwords whose time in the history is up.
///
/// `ClipboardMonitor` runs it on every poll, not only when the pasteboard changed, so a password leaves the history
/// on time while nothing is copied. Polling starts again with a poll right after the Mac wakes or the screen is
/// unlocked, so a password that expired meanwhile goes then.
@MainActor
final class PasswordExpiry {
    private let history: any HistoryStore
    private let now: @MainActor () -> Date

    init(history: any HistoryStore, now: @escaping @MainActor () -> Date) {
        self.history = history
        self.now = now
    }

    func removeExpired() {
        history.removeExpired(at: now())
    }
}
