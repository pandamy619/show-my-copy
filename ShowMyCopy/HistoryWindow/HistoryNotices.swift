import SwiftUI

/// The one-line notices above the history list, each with a divider under it: why the last paste only copied
/// (`PasteHintRow`), and that a pin or Undo unpinned the oldest pinned entry (`PinLimitNoticeRow`). Each stays until
/// the user dismisses it or the window opens again.
struct HistoryNotices: View {
    let model: HistoryWindowModel
    /// Shows Settings on a page, or on the page they show with nil.
    let onOpenSettings: @MainActor (SettingsSection?) -> Void

    var body: some View {
        if let hint = model.pasteHint {
            PasteHintRow(
                hint: hint,
                onOpenSettings: { onOpenSettings(SettingsSection.showing(hint)) },
                onDismiss: { model.pasteHint = nil }
            )
            Divider()
        }
        if model.showsPinLimitNotice {
            PinLimitNoticeRow {
                model.showsPinLimitNotice = false
            }
            Divider()
        }
    }
}
