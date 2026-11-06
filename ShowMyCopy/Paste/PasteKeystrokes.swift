/// Whether macOS lets the app post key events: System Settings → Privacy & Security → Accessibility, which macOS
/// shows for two separate privileges. The app asks only for the narrower one, posting events (`PostEvent` in
/// `tccutil`), with `CGPreflightPostEventAccess` and `CGRequestPostEventAccess`. It never asks for the full
/// Accessibility privilege (reading other apps' windows), which the sandbox does not allow, nor for Input Monitoring
/// (reading what the user types).
///
/// The real one is `SystemPasteKeystrokes`; tests use a fake.
@MainActor
protocol PasteAccessChecking: AnyObject {
    /// Whether the app may post key events now. Asks macOS without showing anything.
    func isGranted() -> Bool

    /// Asks macOS for the privilege. macOS shows its own alert, which leads to System Settings, while it still asks
    /// for this app; afterwards the user turns the app on or off there. Returns whether the app may post events now.
    @discardableResult
    func request() -> Bool
}

/// Sends ⌘V to the app in front, as if the user pressed it. The real one is `SystemPasteKeystrokes`.
@MainActor
protocol PasteKeystrokePosting: AnyObject {
    /// Posts ⌘V as `style` says. Returns false when the events could not be made; then none was posted. macOS drops
    /// posted events without telling the app when it lacks the privilege, so callers check
    /// `PasteAccessChecking.isGranted()` first.
    func postPaste(_ style: PastePostingStyle) -> Bool
}
