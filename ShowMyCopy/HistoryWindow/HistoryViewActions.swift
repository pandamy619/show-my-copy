/// What the history window's content asks its controller to do (`HistoryContentFactory`).
struct HistoryViewActions {
    /// Copies the entry, and pastes it into the app in front when the flag is true.
    let choose: @MainActor (ClipboardEntry, Bool) -> Void
    let close: @MainActor () -> Void
    let openSettings: @MainActor () -> Void
    /// A row is being dragged into another app (`RowDragSource`).
    let drag: @MainActor (RowDragEvent) -> Void
    /// Copies text the user selected, such as a file's folder in the preview, without recording it.
    let copyText: @MainActor (String) -> Void
}
