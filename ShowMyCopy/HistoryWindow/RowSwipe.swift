import Foundation
import Observation

/// Swipe to delete in the history window: a row slides left to show a Delete button, as in Mail. Fed by a two-finger
/// horizontal scroll on a trackpad (`scroll(_:on:)`) or by dragging the row with the mouse (`drag(_:on:)`); the view
/// only shows the offset and passes on the scroll events this leaves to the list.
///
/// Each gesture first moves `axisLockDistance` undecided, then locks to one axis. A horizontal one slides its row, and
/// the list does not see it or its momentum; a vertical one scrolls the list and closes the row that shows its
/// button. On release a row slid at least `holdThreshold` keeps showing its button; one slid at least
/// `fullSwipeThreshold` is deleted at once; any other slides back. Only one row shows its button at a time: swiping
/// another row closes it, and so do a mouse wheel, typing, a key, a change of selection and a click
/// (`close()`).
@MainActor
@Observable
final class RowSwipe {
    /// Width of the Delete button a row shows after a swipe.
    static let buttonWidth: CGFloat = 80
    /// A row released at least this far keeps showing its button; a shorter swipe slides back.
    static let holdThreshold: CGFloat = buttonWidth / 2
    /// A row released at least this far is deleted at once. About 40% of the history window's width.
    static let fullSwipeThreshold: CGFloat = 200
    /// The row never slides further than this.
    static let maximumOffset: CGFloat = 320
    /// How far the fingers or the mouse move before the gesture locks to swiping a row or scrolling the list.
    static let axisLockDistance: CGFloat = 6

    /// A scroll event's gesture phase (`NSEvent.phase`).
    enum Phase: Sendable {
        /// A mouse wheel or another device that does not report gestures.
        case none
        /// Fingers touched the trackpad.
        case mayBegin
        case began
        case changed
        case ended
        case cancelled
    }

    /// One scroll event over a row.
    struct Scroll: Equatable, Sendable {
        var phase: Phase
        /// Whether it is part of the momentum after the fingers left the trackpad (`NSEvent.momentumPhase`).
        var isMomentum = false
        /// How far the fingers moved since the last event, in points; negative to the left. The same with and
        /// without natural scrolling.
        var deltaX: CGFloat = 0
        var deltaY: CGFloat = 0
    }

    /// What the view does with an event.
    enum Outcome: Equatable, Sendable {
        /// Not part of a row swipe: the list scrolls with it. The end of every gesture goes on to the list too, so
        /// the list sees each gesture it saw begin also end.
        case pass
        /// Part of a row swipe: the list does not see it.
        case consume
        /// A full swipe was released: delete this entry. The event goes on to the list, as in `pass`.
        case delete(ClipboardEntry.ID)
    }

    private enum Axis {
        case horizontal
        case vertical
    }

    /// The gesture in progress.
    private struct Gesture {
        let rowID: ClipboardEntry.ID
        /// The row's offset when the gesture began: a row that shows its button slides on from there.
        let startOffset: CGFloat
        var movedX: CGFloat = 0
        var movedY: CGFloat = 0
        /// Nil until the gesture moved `axisLockDistance`.
        var axis: Axis?
    }

    /// The row that is being swiped or shows its button.
    private(set) var rowID: ClipboardEntry.ID?
    /// How far `rowID` slid left.
    private(set) var offset: CGFloat = 0
    /// Whether the fingers or the mouse still move `rowID`.
    private(set) var isTracking = false
    @ObservationIgnored private var gesture: Gesture?
    /// Whether the momentum after the last gesture belongs to a row swipe, so the list must not scroll with it.
    @ObservationIgnored private var swallowsMomentum = false

    /// The row that shows its Delete button and keeps it until closed. Nil while a row is being swiped.
    var swipedRowID: ClipboardEntry.ID? {
        isTracking || offset == 0 ? nil : rowID
    }

    func offset(of id: ClipboardEntry.ID) -> CGFloat {
        id == rowID ? offset : 0
    }

    /// Whether the fingers or the mouse move this row now: then it follows them without animation.
    func isTracking(_ id: ClipboardEntry.ID) -> Bool {
        isTracking && id == rowID
    }

    /// How far the row is drawn slid left. With Reduce Motion it does not follow the fingers: it shows the whole
    /// button once the swipe is past `holdThreshold`, and nothing before.
    func displayedOffset(of id: ClipboardEntry.ID, reducesMotion: Bool) -> CGFloat {
        let offset = offset(of: id)
        guard reducesMotion else {
            return offset
        }
        return offset >= Self.holdThreshold ? Self.buttonWidth : 0
    }

    /// A scroll event over the row of `id`. Events after the first of a gesture belong to the row it began on.
    func scroll(_ event: Scroll, on id: ClipboardEntry.ID) -> Outcome {
        if event.isMomentum {
            return swallowsMomentum ? .consume : .pass
        }
        switch event.phase {
        case .none:
            close()
            return .pass
        case .mayBegin:
            return .pass
        case .began:
            swallowsMomentum = false
            gesture = Gesture(rowID: id, startOffset: offset(of: id))
            return move(byX: event.deltaX, y: event.deltaY)
        case .changed:
            return move(byX: event.deltaX, y: event.deltaY)
        case .ended:
            return end(deletes: true)
        case .cancelled:
            return end(deletes: false)
        }
    }

    /// The mouse dragged the row of `id` by `translation` since the button went down.
    func drag(_ translation: CGSize, on id: ClipboardEntry.ID) {
        if gesture?.rowID != id {
            gesture = Gesture(rowID: id, startOffset: offset(of: id))
        }
        if let gesture {
            _ = move(byX: translation.width - gesture.movedX, y: translation.height - gesture.movedY)
        }
    }

    /// The mouse button went up after a drag. Returns the entry to delete after a full swipe.
    func endDrag() -> ClipboardEntry.ID? {
        if case .delete(let id) = end(deletes: true) {
            return id
        }
        return nil
    }

    /// Slides the row back at once and drops the gesture in progress, if any.
    func close() {
        gesture = nil
        // Only real changes, so a key press or a new selection does not redraw every row.
        if isTracking {
            isTracking = false
        }
        if rowID != nil {
            rowID = nil
        }
        if offset != 0 {
            offset = 0
        }
    }

    private func move(byX deltaX: CGFloat, y deltaY: CGFloat) -> Outcome {
        guard var gesture else {
            return .pass
        }
        gesture.movedX += deltaX
        gesture.movedY += deltaY
        if gesture.axis == nil {
            let distance = (gesture.movedX * gesture.movedX + gesture.movedY * gesture.movedY).squareRoot()
            if distance >= Self.axisLockDistance {
                gesture.axis = abs(gesture.movedX) > abs(gesture.movedY) ? .horizontal : .vertical
                if gesture.axis == .horizontal {
                    // Swiping another row closes the one that showed its button.
                    rowID = gesture.rowID
                    isTracking = true
                } else {
                    // Scrolling closes it too.
                    close()
                }
            }
        }
        self.gesture = gesture
        guard gesture.axis == .horizontal else {
            return .pass
        }
        let slid = min(max(gesture.startOffset - gesture.movedX, 0), Self.maximumOffset)
        if slid != offset {
            offset = slid
        }
        return .consume
    }

    private func end(deletes: Bool) -> Outcome {
        guard let gesture else {
            return .pass
        }
        self.gesture = nil
        guard gesture.axis == .horizontal else {
            return .pass
        }
        swallowsMomentum = true
        isTracking = false
        if deletes, offset >= Self.fullSwipeThreshold {
            close()
            return .delete(gesture.rowID)
        }
        if offset >= Self.holdThreshold {
            offset = Self.buttonWidth
        } else {
            close()
        }
        return .pass
    }
}
