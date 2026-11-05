import SwiftUI

/// The one-line notices above the history list, each with a divider under it: why the last paste only copied
/// (`PasteHintRow`), and that a pin or Undo unpinned the oldest pinned entry (`PinLimitNoticeRow`). Each stays until
/// the user dismisses it or the window opens again.
struct HistoryNotices: View {
    let model: HistoryWindowModel
    let onOpenSettings: @MainActor () -> Void

    var body: some View {
        if let hint = model.pasteHint {
            PasteHintRow(hint: hint, onOpenSettings: onOpenSettings) {
                model.pasteHint = nil
            }
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
