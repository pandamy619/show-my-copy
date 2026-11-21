import Foundation

/// Puts a code on the pasteboard when the user picks an account in the history window, and takes it off again.
///
/// The code is written like text copied from the preview (`EntryCopier.copyText`): with `PasteboardMarker.unrecorded`,
/// so the history never records it, and with the concealed marker, so other clipboard managers skip it. One code
/// period after the copy, the clipboard is emptied when it still holds the code, as for a password whose time is up.
@MainActor
final class CodeCopier: CodeCopying {
    private let history: any HistoryStore
    private let pasteboard: any PasteboardWriting
    private let monitor: any PasteboardChangeTracking
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    /// The clearing scheduled by the last copy. Tests await it.
    private(set) var pendingClear: Task<Void, Never>?

    init(
        history: any HistoryStore,
        pasteboard: any PasteboardWriting,
        monitor: any PasteboardChangeTracking,
        now: @escaping @MainActor () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.history = history
        self.pasteboard = pasteboard
        self.monitor = monitor
        self.now = now
        self.sleep = sleep
    }

    /// Copies the code of `account` as it is now. Returns the pasteboard's change count after the write, so a paste
    /// afterwards pastes exactly that, or nil when the code did not end up on the pasteboard.
    @discardableResult
    func copy(_ account: CodeAccount) -> Int? {
        let code = account.code(at: now())
        monitor.poll()
        guard let changeCount = pasteboard.writeUnrecorded(code.digits, concealed: true) else {
            AppLogger.clipboard.info("Could not put the code on the pasteboard")
            return nil
        }
        monitor.acknowledge(changeCount: changeCount)
        history.markCurrentSkipped()
        scheduleClear(changeCount: changeCount, after: .seconds(max(account.account.period, 1)))
        return changeCount
    }

    /// Empties the pasteboard after `delay` when it still holds the code written at `changeCount`. A newer copy
    /// replaces the clearing scheduled before: only the latest code is taken off.
    private func scheduleClear(changeCount: Int, after delay: Duration) {
        pendingClear?.cancel()
        pendingClear = Task { [sleep] in
            do {
                try await sleep(delay)
            } catch {
                return  // Replaced by a newer copy.
            }
            guard let cleared = pasteboard.clearContents(ifChangeCountIs: changeCount) else {
                return
            }
            monitor.acknowledge(changeCount: cleared)
            AppLogger.clipboard.debug("Emptied the pasteboard, which held a code whose time is up")
        }
    }
}
