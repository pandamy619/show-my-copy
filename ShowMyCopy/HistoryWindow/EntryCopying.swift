/// Puts an entry the user picked back on the pasteboard. `EntryCopier` is the app's implementation; the history
/// window only needs to know whether the copy worked, to decide whether to close, and which pasteboard change it
/// made, so a paste afterwards pastes exactly that.
@MainActor
protocol EntryCopying: AnyObject {
    /// Returns the pasteboard's change count after the write, or nil when the content did not end up on the
    /// pasteboard.
    @discardableResult
    func copy(_ entry: ClipboardEntry) -> Int?

    /// Puts text the user selected in the window and copied by hand, such as a file's folder, on the pasteboard
    /// without recording it. Returns the change count after the write, or nil when nothing was written.
    @discardableResult
    func copyText(_ text: String) -> Int?
}
