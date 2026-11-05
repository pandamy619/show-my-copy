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

/// The row's context menu, built from its actions (`RowAction.offers(for:)`): Show Preview, Pin or Unpin, and
/// Delete. A dimmed item does nothing.
struct RowContextMenu: ViewModifier {
    let entry: ClipboardEntry
    let model: HistoryWindowModel

    func body(content: Content) -> some View {
        content
            .contextMenu {
                ForEach(RowAction.offers(for: entry), id: \.action) { offer in
                    Button(offer.action.menuTitle, role: offer.action.isDestructive ? .destructive : nil) {
                        model.perform(offer.action, on: entry)
                    }
                    .disabled(!offer.isEnabled)
                }
            }
    }
}

/// Offers VoiceOver users the row's actions that can be used now, from the same list as the context menu and the
/// swipe buttons, so every swipe button is also an action. A password's row has no Pin.
struct RowActionsAccessibility: ViewModifier {
    let entry: ClipboardEntry
    let model: HistoryWindowModel

    func body(content: Content) -> some View {
        content
            .accessibilityActions {
                ForEach(RowAction.offers(for: entry).filter(\.isEnabled), id: \.action) { offer in
                    Button(offer.action.menuTitle) {
                        model.perform(offer.action, on: entry)
                    }
                }
            }
    }
}

/// How each action looks in the context menu, as a VoiceOver action and as a swipe button.
extension RowAction {
    /// The context menu item and the VoiceOver action.
    var menuTitle: LocalizedStringKey {
        switch self {
        case .showPreview:
            "Show Preview"
        case .pin:
            "Pin"
        case .unpin:
            "Unpin"
        case .delete:
            "Delete"
        }
    }

    /// The short label under a swipe button's symbol.
    var buttonTitle: LocalizedStringKey {
        switch self {
        case .showPreview:
            "Preview"
        case .pin:
            "Pin"
        case .unpin:
            "Unpin"
        case .delete:
            "Delete"
        }
    }

    var systemImage: String {
        switch self {
        case .showPreview:
            "eye"
        case .pin:
            "pin"
        case .unpin:
            "pin.slash"
        case .delete:
            "trash"
        }
    }

    /// Delete is red; the others are not, so it stands out at the edge.
    var swipeColor: Color {
        switch self {
        case .showPreview:
            .blue
        case .pin, .unpin:
            .orange
        case .delete:
            .red
        }
    }
}
