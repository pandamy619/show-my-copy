import SwiftUI

/// Shows or hides the text of one concealed entry until the window closes.
struct RevealButton: View {
    let isRevealed: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
        }
        .buttonStyle(.borderless)
        .help(isRevealed ? Text("Hide password") : Text("Show password"))
        .accessibilityLabel(isRevealed ? Text("Hide password") : Text("Show password"))
        .padding(.trailing, 10)
    }
}

/// Offers VoiceOver users "Pin" or "Unpin" on a row. A password cannot be pinned, so its row has neither.
struct PinAccessibility: ViewModifier {
    let entry: ClipboardEntry
    let model: HistoryWindowModel

    @ViewBuilder
    func body(content: Content) -> some View {
        if HistoryWindowModel.canPin(entry) {
            content
                .accessibilityAction(named: entry.isPinned ? Text("Unpin") : Text("Pin")) {
                    model.togglePin(entry)
                }
        } else {
            content
        }
    }
}
