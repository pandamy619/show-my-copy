import Foundation

/// Swipe to delete (`RowSwipe`): what the history window's rows ask of the model.
extension HistoryWindowModel {
    /// A scroll event over the row of `entry`. Returns whether the row took it; the list scrolls with any other.
    /// A full swipe deletes the entry, like ⌘⌫.
    func swipeScrolled(_ scroll: RowSwipe.Scroll, on entry: ClipboardEntry) -> Bool {
        switch swipe.scroll(scroll, on: entry.id) {
        case .pass:
            return false
        case .consume:
            return true
        case .delete(let id):
            deleteSwiped(id)
            return false
        }
    }

    /// The mouse dragged the row of `entry` by `translation` since the button went down.
    func swipeDragged(_ translation: CGSize, on entry: ClipboardEntry) {
        swipe.drag(translation, on: entry.id)
    }

    /// The mouse button went up after dragging a row. A full swipe deletes the entry, like ⌘⌫.
    func swipeDragEnded() {
        if let id = swipe.endDrag() {
            deleteSwiped(id)
        }
    }

    /// Closes the row that shows its Delete button, for a click on any row: then the click does nothing else.
    /// Returns whether a listed row showed its button.
    @discardableResult
    func closeSwipedRow() -> Bool {
        let wasShown = swipe.swipedRowID.map { id in items.contains { $0.id == id } } ?? false
        swipe.close()
        return wasShown
    }

    /// Deletes the listed entry with `id`, the history's copy, which can be newer than the row the swipe began on.
    private func deleteSwiped(_ id: ClipboardEntry.ID) {
        if let entry = items.first(where: { $0.id == id }) {
            delete(entry)
        }
    }
}
