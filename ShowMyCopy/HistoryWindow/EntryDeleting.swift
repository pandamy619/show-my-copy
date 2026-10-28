/// Deletes entries the user picked in the history window, and brings the last one back on Undo. `EntryDeleter` is
/// the app's implementation; the history window model only decides which entry and what to select afterwards.
@MainActor
protocol EntryDeleting: AnyObject {
    /// Removes the entry from the history and from disk. When it is what the pasteboard holds and nothing was copied
    /// since, the pasteboard is emptied too.
    func delete(_ id: ClipboardEntry.ID)

    /// Whether `undoDelete()` has an entry to bring back.
    var canUndoDelete: Bool { get }

    /// Puts the last deleted entry back in the history, with its data. Returns the ID of the entry that holds its
    /// content afterwards, or nil when there was nothing to bring back or it may not come back (a password whose
    /// time is up).
    @discardableResult
    func undoDelete() -> ClipboardEntry.ID?

    /// Ends the chance to undo: the last deleted entry's files are deleted now. Called when the history window
    /// closes.
    func finishDeleting()
}
