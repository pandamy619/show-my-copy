import Foundation

extension HistoryWindowModel {
    /// Whether `entry` can be pinned. A password cannot: it keeps its own expiry, which a pin would outlast.
    nonisolated static func canPin(_ entry: ClipboardEntry) -> Bool {
        !entry.isConcealed
    }

    /// Pins `entry`, or unpins it when it is pinned now, for ⌘P, the row's "Pin" or "Unpin" action and VoiceOver.
    /// The entry moves to its new section; the selection is kept by ID, so it moves with it. A password is left as
    /// it is. Pinning one past `RetentionPolicy.maximumPinned` unpins the oldest pinned entry, and the window says so.
    func togglePin(_ entry: ClipboardEntry) {
        // The history's own copy: a row's entry can be older than the last change.
        guard let entry = history.entries.first(where: { $0.id == entry.id }), Self.canPin(entry) else {
            return
        }
        noticingPinLimit(acting: entry.id) {
            history.setPinned(!entry.isPinned, id: entry.id)
        }
    }

    /// Runs `body`, a pin or an Undo, and shows the pin limit notice when it unpinned an entry other than `acting`,
    /// the one the user unpinned. Only the limit unpins entries the user did not act on (`HistoryStore.setPinned`
    /// and `restore`), and `body` runs on the main actor with nothing in between, so comparing before and after is
    /// exact. Hides the notice when it unpinned none: it is about the last action only.
    @discardableResult
    func noticingPinLimit<Result>(acting: ClipboardEntry.ID?, _ body: () -> Result) -> Result {
        let pinnedBefore = Set(history.entries.lazy.filter(\.isPinned).map(\.id))
        let result = body()
        let unpinnedByLimit = history.entries.contains { entry in
            !entry.isPinned && entry.id != acting && pinnedBefore.contains(entry.id)
        }
        showsPinLimitNotice = unpinnedByLimit
        return result
    }
}
