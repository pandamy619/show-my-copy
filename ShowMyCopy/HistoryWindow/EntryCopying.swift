/// Puts an entry the user picked back on the pasteboard. `EntryCopier` is the app's implementation; the history
/// window only needs to know whether the copy worked, to decide whether to close.
@MainActor
protocol EntryCopying: AnyObject {
    /// Returns false when the content did not end up on the pasteboard.
    @discardableResult
    func copy(_ entry: ClipboardEntry) -> Bool
}
