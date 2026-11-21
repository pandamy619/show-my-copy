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
        /// Copy this account's code to the clipboard, and paste it when `pastes` is true.
        case copyCode(CodeAccount, pastes: Bool)
        /// Close the history window.
        case close
    }
}

// MARK: - Handling keys

extension HistoryWindowModel {
    /// Handles a key press. `isCaretAtEnd` is false while the caret of the search field is not after its last
    /// character: then Left and Right Arrow move the caret instead.
    ///
    /// Up and Down Arrow move the selection, and the open preview follows it. Right Arrow opens the preview, like
    /// opening a folder in a column view; Left Arrow and Esc close it. Esc with no preview closes the window, and
    /// Return copies the selected entry back, or the selected account's code, and pastes it when Settings say so;
    /// ⌥Return does the other. ⌘⌫ deletes the selected entry and ⌘Z brings it back; with nothing to delete or bring
    /// back, or a code selected, they are left to the search field. ⌘P pins or unpins the selected entry.
    func handleKey(_ key: Key, isCaretAtEnd: Bool) -> KeyResult {
        // Any of these keys closes a swiped row, as typing does.
        swipe.close()
        switch key {
        case .delete, .undo, .pin:
            return handleCommandKey(key)
        case .up, .down:
            moveSelection(key == .up ? .up : .down)
            if preview.isOpen {
                showPreviewOfSelection()
            }
            return .handled
        case .right:
            return previewSelection(isCaretAtEnd: isCaretAtEnd)
        case .left:
            guard preview.isOpen else {
                return .ignored
            }
            preview.close()
            return .handled
        case .escape:
            guard preview.isOpen else {
                return .close
            }
            preview.close()
            return .handled
        case .return, .optionReturn:
            return chooseSelected(pastes: choosingPastes(isAlternate: key == .optionReturn))
        }
    }

    /// Right Arrow: opens the preview of the selected entry, when there is one that can be previewed and the caret
    /// is at the end of the search text. Otherwise the key is left to the search field.
    private func previewSelection(isCaretAtEnd: Bool) -> KeyResult {
        guard !preview.isOpen, isCaretAtEnd, let entry = selectedEntry, EntryPreviewModel.canPreview(entry) else {
            return .ignored
        }
        preview.open(entry)
        return .handled
    }

    /// Return: what the view does with the selected row, an entry or a code. Nothing with nothing listed.
    private func chooseSelected(pastes: Bool) -> KeyResult {
        switch selectedItem {
        case .entry(let entry):
            .choose(entry, pastes: pastes)
        case .code(let account):
            .copyCode(account, pastes: pastes)
        case nil:
            .handled
        }
    }

    /// ⌘⌫ and ⌘Z, left to the search field when there is nothing to delete or bring back, and ⌘P, always handled.
    private func handleCommandKey(_ key: Key) -> KeyResult {
        if key == .pin {
            if let entry = selectedEntry {
                togglePin(entry)
            }
            return .handled
        }
        if key == .undo {
            guard canUndoDelete else {
                return .ignored
            }
            undoDelete()
            return .handled
        }
        guard let entry = selectedEntry else {
            return .ignored
        }
        delete(entry)
        return .handled
    }
}
