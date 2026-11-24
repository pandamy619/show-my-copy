/// The app's global shortcuts, each recorded in Settings → General. What macOS registers them under is in
/// `KeyboardShortcuts+Names.swift`; the views only name them, so they do not depend on the package.
enum GlobalShortcut: CaseIterable, Sendable {
    /// Opens and closes the history window.
    case showHistory
    /// Shows and hides the codes of the open history window, the first one selected when they appear. It never
    /// opens the window.
    case showCodes
}
