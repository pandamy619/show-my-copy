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
/// Delete for an entry; Copy Code and Remove Account for a code. A dimmed item does nothing.
struct RowContextMenu: ViewModifier {
    let row: HistoryRowItem
    let perform: @MainActor (RowAction) -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                ForEach(RowAction.offers(for: row), id: \.action) { offer in
                    Button(offer.action.menuTitle, role: offer.action.isDestructive ? .destructive : nil) {
                        perform(offer.action)
                    }
                    .disabled(!offer.isEnabled)
                }
            }
    }
}

/// Offers VoiceOver users the row's actions that can be used now, from the same list as the context menu and the
/// swipe buttons, so every swipe button is also an action. A password's row has no Pin.
struct RowActionsAccessibility: ViewModifier {
    let row: HistoryRowItem
    let perform: @MainActor (RowAction) -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityActions {
                ForEach(RowAction.offers(for: row).filter(\.isEnabled), id: \.action) { offer in
                    Button(offer.action.menuTitle) {
                        perform(offer.action)
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
        case .copyCode:
            "Copy Code"
        case .removeAccount:
            "Remove Account"
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
        case .copyCode:
            "Copy"
        case .removeAccount:
            "Remove"
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
        case .copyCode:
            "doc.on.doc"
        case .removeAccount:
            "minus.circle"
        }
    }

    /// Delete and Remove Account are red; the others are not, so they stand out at the edge.
    var swipeColor: Color {
        switch self {
        case .showPreview, .copyCode:
            .blue
        case .pin, .unpin:
            .orange
        case .delete, .removeAccount:
            .red
        }
    }
}
