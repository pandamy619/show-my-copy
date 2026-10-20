import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Opens and closes the history window. ⌘⇧V by default; the user can change or clear it in Settings.
    static let toggleHistoryWindow = Self("toggleHistoryWindow", initial: .init(.v, modifiers: [.command, .shift]))
}
