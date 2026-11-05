import SwiftUI

/// One line above the list after a pin or Undo unpinned the oldest pinned entry to keep
/// `RetentionPolicy.maximumPinned` (`HistoryWindowModel.showsPinLimitNotice`). The unpinned entry is at the top of
/// History; nothing is deleted, so it is a note, not a warning.
struct PinLimitNoticeRow: View {
    let onDismiss: @MainActor () -> Void

    /// The notice, also for VoiceOver to announce when it appears.
    static var message: String {
        String(localized: "Unpinned the oldest pinned entry to keep \(RetentionPolicy.maximumPinned).")
    }

    /// Tells VoiceOver the notice, each time it is shown (`HistoryWindowModel.pinLimitNoticeCount`).
    static func announce() {
        AccessibilityNotification.Announcement(message).post()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "pin.slash")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(Self.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
