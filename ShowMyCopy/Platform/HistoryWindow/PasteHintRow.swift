import SwiftUI

/// One line above the list, shown once after choosing an entry to paste only copied it (`PasteFallback`): why, and a
/// way to Settings, where pasting is allowed.
struct PasteHintRow: View {
    let hint: PasteFallback
    let onOpenSettings: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(Self.message(for: hint))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Settings…") {
                onOpenSettings()
            }
            .controlSize(.small)
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

    private static func message(for hint: PasteFallback) -> LocalizedStringKey {
        switch hint {
        case .noAccess:
            "Copied, not pasted: Show My Copy is not allowed to paste. Allow it in Settings."
        case .couldNotPost:
            "Copied, not pasted: Show My Copy could not paste into the app."
        }
    }
}
