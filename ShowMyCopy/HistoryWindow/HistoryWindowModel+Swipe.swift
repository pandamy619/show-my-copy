import Foundation

/// Swiping a row (`RowSwipe`): what the history window's rows ask of the model.
extension HistoryWindowModel {
    /// A scroll event over the row of `entry`. Returns whether the row took it; the list scrolls with any other.
    /// The row opens as wide as the buttons of its actions (`RowAction.offers(for:)`). A full swipe deletes the
    /// entry, like ⌘⌫.
    func swipeScrolled(_ scroll: RowSwipe.Scroll, on entry: ClipboardEntry) -> Bool {
        let actionsWidth = RowSwipe.actionsWidth(buttonCount: RowAction.offers(for: entry).count)
        switch swipe.scroll(scroll, on: entry.id, actionsWidth: actionsWidth) {
        case .pass:
            return false
        case .consume:
            return true
        case .delete(let id):
            deleteSwiped(id)
            return false
        }
    }

    /// Closes the open row, for a click on any row: then the click does nothing else. Returns whether a listed row
    /// was open.
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
