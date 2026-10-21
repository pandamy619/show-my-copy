import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Opens and closes the history window. ⌥⌘V by default; the user can change or clear it in Settings.
    /// Not ⇧⌘V: a global shortcut takes the keys from every app, and many apps use ⇧⌘V for Paste and Match Style.
    static let toggleHistoryWindow = Self("toggleHistoryWindow", initial: .init(.v, modifiers: [.option, .command]))
}
