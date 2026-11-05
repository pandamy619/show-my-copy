import SwiftUI

/// A question shown in place, with a destructive confirm button and a cancel button.
struct InlineConfirmation: View {
    let message: Text
    /// A second, smaller line, such as how much space the change frees.
    var detail: Text?
    let confirmTitle: LocalizedStringKey
    let onConfirm: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                message
                if let detail {
                    detail
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Cancel", action: onCancel)
            Button(confirmTitle, role: .destructive, action: onConfirm)
        }
        .accessibilityElement(children: .contain)
    }
}

extension Text {
    /// The question before a lower limit removes entries.
    static func removingOldestItems(_ count: Int) -> Text {
        // The catalog has plural variations, including "This removes your 1 oldest item." for one.
        Text("This removes \(count) of your oldest items.")
    }

    /// The space a removal frees. A line of its own, so plural strings depend on the count alone.
    static func freeing(bytes: Int) -> Text {
        Text("Frees \(ByteCount.fileSize(bytes)).")
    }

    /// The space a lower limit frees and, when the history has pinned entries, that the limit keeps them: they
    /// count toward the history's size but no limit removes them.
    static func freeing<Limit>(_ change: LimitChange<Limit>) -> Text {
        guard change.keptPinnedCount > 0 else {
            return freeing(bytes: change.freedBytes)
        }
        return Text("Frees \(ByteCount.fileSize(change.freedBytes)). Pinned entries are kept.")
    }
}
