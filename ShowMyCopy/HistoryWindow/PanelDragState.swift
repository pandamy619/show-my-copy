/// A drag of a row out of the history window, as the row reports it.
enum RowDragEvent: Equatable, Sendable {
    case began
    /// `dropped` is true when an app took the drop. A drag can only be dropped outside this app: the history window
    /// accepts none of its own rows, so a drop on it counts as cancelled.
    case ended(dropped: Bool)
}

/// Whether the history panel stays open while the user drags an entry out of it.
///
/// The panel closes when it loses key focus (`HistoryWindowController.windowDidResignKey`). While a drag is in
/// progress it does not: the user is still working with it. A drag that drops the entry in another app closes the
/// panel, as choosing an entry does. A cancelled drag leaves it open, and gives it key focus back if it lost it
/// meanwhile, so the keyboard works again and a click outside closes it as usual.
struct PanelDragState: Equatable, Sendable {
    /// What the panel does when a drag ends.
    enum Ending: Equatable, Sendable {
        /// The entry was dropped in another app: close the panel.
        case close
        /// Cancelled: stay open, and become key again when `restoresKey`.
        case stayOpen(restoresKey: Bool)
        /// No drag was in progress, for example because the panel closed meanwhile: do nothing.
        case ignore
    }

    private(set) var isDragging = false
    /// Whether the panel lost key focus during the drag, so it did not close then.
    private var lostKeyWhileDragging = false

    mutating func began() {
        isDragging = true
        lostKeyWhileDragging = false
    }

    /// The panel lost key focus. Returns whether it closes now, which it does unless a drag is in progress.
    mutating func panelResignedKey() -> Bool {
        guard isDragging else {
            return true
        }
        lostKeyWhileDragging = true
        return false
    }

    mutating func ended(dropped: Bool) -> Ending {
        guard isDragging else {
            return .ignore
        }
        let restoresKey = lostKeyWhileDragging
        reset()
        return dropped ? .close : .stayOpen(restoresKey: restoresKey)
    }

    /// Forgets the drag in progress, for a panel that closes or opens: a drag that ends after that changes nothing.
    mutating func reset() {
        isDragging = false
        lostKeyWhileDragging = false
    }
}
