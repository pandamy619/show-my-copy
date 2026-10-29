import Foundation

extension HistoryWindowModel {
    /// Whether `entry` can be pinned. A password cannot: it keeps its own expiry, which a pin would outlast.
    nonisolated static func canPin(_ entry: ClipboardEntry) -> Bool {
        !entry.isConcealed
    }

    /// Pins `entry`, or unpins it when it is pinned now, for ⌘P, the row's "Pin" or "Unpin" action and VoiceOver.
    /// The entry moves to its new section; the selection is kept by ID, so it moves with it. A password is left as
    /// it is.
    func togglePin(_ entry: ClipboardEntry) {
        // The history's own copy: a row's entry can be older than the last change.
        guard let entry = history.entries.first(where: { $0.id == entry.id }), Self.canPin(entry) else {
            return
        }
        history.setPinned(!entry.isPinned, id: entry.id)
    }
}
