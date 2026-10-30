/// Puts an entry the user picked back on the pasteboard. `EntryCopier` is the app's implementation; the history
/// window only needs to know whether the copy worked, to decide whether to close, and which pasteboard change it
/// made, so a paste afterwards pastes exactly that.
@MainActor
protocol EntryCopying: AnyObject {
    /// Returns the pasteboard's change count after the write, or nil when the content did not end up on the
    /// pasteboard.
    @discardableResult
    func copy(_ entry: ClipboardEntry) -> Int?
}
