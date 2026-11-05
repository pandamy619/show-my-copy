import Foundation

/// The keys the history window model handles and what it asks of the view, kept apart from the model's state.
extension HistoryWindowModel {
    enum Direction: Sendable {
        case up
        case down
    }

    /// The keys the history window handles, whether the search field or the list has focus.
    enum Key: Sendable {
        case up
        case down
        case left
        case right
        /// Return: copies the selected entry, and pastes it too when Settings → General → Paste after choosing an
        /// entry is on.
        case `return`
        /// ⌥Return: the other way round from Return. It only copies while pasting is on, and pastes while it is off.
        case optionReturn
        case escape
        /// ⌘⌫: deletes the selected entry. Delete without ⌘ edits the search text.
        case delete
        /// ⌘Z: brings back the entry deleted last, while there is one. Otherwise it undoes typing in the search field.
        case undo
        /// ⌘P: pins or unpins the selected entry. Always handled, so it never reaches the search field or Print.
        case pin
    }

    /// What the view does after the model handled a key.
    enum KeyResult: Equatable {
        /// The model handled it; nothing else to do.
        case handled
        /// Not for the history window: the search field gets it, for example to move the caret.
        case ignored
        /// Copy this entry back to the clipboard, and paste it into the app in front when `pastes` is true.
        case choose(ClipboardEntry, pastes: Bool)
        /// Close the history window.
        case close
    }
}
