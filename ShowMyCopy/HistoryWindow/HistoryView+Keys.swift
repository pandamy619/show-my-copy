import AppKit
import SwiftUI

/// The keys the history view handles itself and hands to the model (`HistoryWindowModel.handleKey`).
extension HistoryView {
    func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // While an input method composes text (Japanese, Chinese, Korean), these keys move between and confirm
        // its candidates or cancel the composition. Leave them to the search field.
        guard !Self.isComposingText else {
            return .ignored
        }
        guard let key = Self.historyKey(for: press) else {
            return .ignored
        }
        switch model.handleKey(key, isCaretAtEnd: Self.isCaretAtEnd) {
        case .handled:
            return .handled
        case .ignored:
            return .ignored
        case .choose(let entry, let pastes):
            onChoose(entry, pastes)
            return .handled
        case .copyCode(let account, let pastes):
            onChooseCode(account, pastes)
            return .handled
        case .close:
            onClose()
            return .handled
        }
    }

    /// The model's name for a key press, or nil for one the history window leaves to the search field.
    private static func historyKey(for press: KeyPress) -> HistoryWindowModel.Key? {
        // Shift, Option, Command or Control with Left or Right Arrow select text or move by word in the search field.
        let editingModifiers: EventModifiers = [.shift, .option, .command, .control]
        let isEditing = !press.modifiers.isDisjoint(with: editingModifiers)
        switch press.key {
        case .upArrow:
            return .up
        case .downArrow:
            return .down
        case .leftArrow:
            return isEditing ? nil : .left
        case .rightArrow:
            return isEditing ? nil : .right
        case .return:
            // ⌥Return does the other of what Return does. With ⌘ or ⌃ as well it is plain Return, as before.
            let isOptionOnly = press.modifiers.intersection([.option, .command, .control]) == .option
            return isOptionOnly ? .optionReturn : .return
        case .escape:
            return .escape
        default:
            return nil
        }
    }

    /// True when the caret of the search field is after its last character with nothing selected, or the search
    /// field is not being edited. Only then does Right Arrow open the preview instead of moving the caret.
    @MainActor private static var isCaretAtEnd: Bool {
        guard let editor = NSApplication.shared.keyWindow?.firstResponder as? NSTextView else {
            return true
        }
        let selection = editor.selectedRange()
        return selection.length == 0 && selection.location >= (editor.string as NSString).length
    }

    /// True while the search field holds marked text: input that an input method has not committed yet.
    @MainActor private static var isComposingText: Bool {
        guard let editor = NSApplication.shared.keyWindow?.firstResponder as? NSTextView else {
            return false
        }
        return editor.hasMarkedText()
    }

    func chooseSelected() {
        switch model.selectedItem {
        case .entry(let entry):
            onChoose(entry, model.choosingPastes(isAlternate: false))
        case .code(let account):
            onChooseCode(account, model.choosingPastes(isAlternate: false))
        case nil:
            break
        }
    }
}
