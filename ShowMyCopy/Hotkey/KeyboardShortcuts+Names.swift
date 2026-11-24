import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Opens and closes the history window. ⌥⌘V by default; the user can change or clear it in Settings.
    /// Not ⇧⌘V: a global shortcut takes the keys from every app, and many apps use ⇧⌘V for Paste and Match Style.
    static let toggleHistoryWindow = Self("toggleHistoryWindow", initial: .init(.v, modifiers: [.option, .command]))

    /// Shows and hides the codes of the open history window (`HistoryWindowController.codesShortcutPressed()`);
    /// it never opens the window. No keys until the user records some in Settings: a global shortcut takes its
    /// keys from every app, and most users have no accounts to show.
    static let showCodes = Self("showCodes")

    static func name(for shortcut: GlobalShortcut) -> Self {
        switch shortcut {
        case .showHistory:
            .toggleHistoryWindow
        case .showCodes:
            .showCodes
        }
    }
}
