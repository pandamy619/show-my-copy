import Foundation
import Testing

@testable import ShowMyCopy

/// A row slides left with a horizontal trackpad swipe or a mouse drag, keeps showing its Delete button past the hold
/// threshold and is deleted past the full-swipe threshold; vertical scrolling goes to the list.
@MainActor
struct RowSwipeTests {
    private let swipe = RowSwipe()
    private let row = UUID()
    private let other = UUID()

    /// A trackpad gesture over `id`: began, one changed event per step and ended. Returns each event's outcome.
    @discardableResult
    private func gesture(
        on id: UUID, steps: [(x: CGFloat, y: CGFloat)], ends: RowSwipe.Phase = .ended
    ) -> [RowSwipe.Outcome] {
        var outcomes = [swipe.scroll(RowSwipe.Scroll(phase: .began), on: id)]
        for step in steps {
            outcomes.append(swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: step.x, deltaY: step.y), on: id))
        }
        outcomes.append(swipe.scroll(RowSwipe.Scroll(phase: ends), on: id))
        return outcomes
    }

    /// A horizontal swipe of `distance` points to the left over `id`, in steps of 10 points.
    @discardableResult
    private func swipeLeft(_ distance: CGFloat, on id: UUID, ends: RowSwipe.Phase = .ended) -> [RowSwipe.Outcome] {
        let count = Int(distance / 10)
        return gesture(on: id, steps: Array(repeating: (x: -10, y: 0), count: count), ends: ends)
    }

    // MARK: - Thresholds

    @Test func thresholdsAreOrdered() {
        #expect(RowSwipe.axisLockDistance < RowSwipe.holdThreshold)
        #expect(RowSwipe.holdThreshold < RowSwipe.buttonWidth)
        #expect(RowSwipe.buttonWidth < RowSwipe.fullSwipeThreshold)
        #expect(RowSwipe.fullSwipeThreshold < RowSwipe.maximumOffset)
    }

    @Test func theRowFollowsTheFingersWhileSwiping() {
        _ = swipe.scroll(RowSwipe.Scroll(phase: .began), on: row)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -30), on: row)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -25), on: row)

        #expect(swipe.offset(of: row) == 55)
        #expect(swipe.isTracking(row))
        #expect(swipe.swipedRowID == nil)
        #expect(swipe.offset(of: other) == 0)
    }

    @Test func aShortSwipeSlidesBack() {
        let outcomes = swipeLeft(30, on: row)

        #expect(swipe.offset(of: row) == 0)
        #expect(swipe.swipedRowID == nil)
        #expect(!swipe.isTracking(row))
        #expect(outcomes.last == .pass)
    }

    @Test func aSwipePastTheHoldThresholdKeepsTheButton() {
        swipeLeft(RowSwipe.holdThreshold + 10, on: row)

        #expect(swipe.offset(of: row) == RowSwipe.buttonWidth)
        #expect(swipe.swipedRowID == row)
        #expect(!swipe.isTracking(row))
    }

    @Test func aSwipeJustShortOfTheFullSwipeKeepsTheButton() {
        let outcomes = swipeLeft(RowSwipe.fullSwipeThreshold - 10, on: row)

        #expect(!outcomes.contains(.delete(row)))
        #expect(swipe.swipedRowID == row)
        #expect(swipe.offset(of: row) == RowSwipe.buttonWidth)
    }

    @Test func aFullSwipeDeletes() {
        let outcomes = swipeLeft(RowSwipe.fullSwipeThreshold, on: row)

        #expect(outcomes.last == .delete(row))
        #expect(swipe.swipedRowID == nil)
        #expect(swipe.offset(of: row) == 0)
    }

    @Test func aCancelledFullSwipeDoesNotDelete() {
        let outcomes = swipeLeft(RowSwipe.fullSwipeThreshold + 20, on: row, ends: .cancelled)

        #expect(!outcomes.contains(.delete(row)))
        #expect(swipe.swipedRowID == row)
    }

    @Test func theRowStopsAtTheMaximumAndNeverSlidesRight() {
        _ = swipe.scroll(RowSwipe.Scroll(phase: .began), on: row)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -1000), on: row)
        #expect(swipe.offset(of: row) == RowSwipe.maximumOffset)

        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: 2000), on: row)
        #expect(swipe.offset(of: row) == 0)
    }

    @Test func swipingRightClosesTheRow() {
        swipeLeft(60, on: row)
        #expect(swipe.swipedRowID == row)

        gesture(on: row, steps: [(x: 30, y: 0), (x: 30, y: 0)])

        #expect(swipe.swipedRowID == nil)
        #expect(swipe.offset(of: row) == 0)
    }

    @Test func aRowThatShowsItsButtonSlidesOnFromThere() {
        swipeLeft(60, on: row)

        _ = swipe.scroll(RowSwipe.Scroll(phase: .began), on: row)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -10), on: row)

        #expect(swipe.offset(of: row) == RowSwipe.buttonWidth + 10)
    }

    // MARK: - Axis lock

    @Test func undecidedMovementGoesToTheList() {
        let outcome = swipe.scroll(RowSwipe.Scroll(phase: .began, deltaX: -2, deltaY: 1), on: row)

        #expect(outcome == .pass)
        #expect(swipe.offset(of: row) == 0)
        #expect(!swipe.isTracking(row))
    }

    @Test func aHorizontalGestureIsTakenFromTheList() {
        let outcomes = gesture(on: row, steps: [(x: -8, y: 2), (x: -10, y: 6)])

        #expect(outcomes[1] == .consume)
        #expect(outcomes[2] == .consume)
        // The end goes on, so the list sees the gesture it saw begin also end.
        #expect(outcomes[3] == .pass)
    }

    @Test func aVerticalGestureScrollsTheListAndNeverSlidesTheRow() {
        let outcomes = gesture(on: row, steps: [(x: -1, y: 8), (x: -40, y: 2), (x: -40, y: 2)])

        #expect(outcomes.allSatisfy { $0 == .pass })
        #expect(swipe.offset(of: row) == 0)
        #expect(swipe.swipedRowID == nil)
    }

    @Test func aDiagonalGestureLocksToItsLargerAxis() {
        gesture(on: row, steps: [(x: -5, y: -4), (x: -60, y: 0)])
        #expect(swipe.swipedRowID == row)

        swipe.close()
        gesture(on: other, steps: [(x: -4, y: 5), (x: -60, y: 0)])
        #expect(swipe.swipedRowID == nil)
    }

    @Test func scrollingTheListClosesTheRow() {
        swipeLeft(60, on: row)

        gesture(on: other, steps: [(x: 0, y: 10)])

        #expect(swipe.swipedRowID == nil)
        #expect(swipe.offset(of: row) == 0)
    }

    @Test func aMouseWheelScrollsAndClosesTheRow() {
        swipeLeft(60, on: row)

        let outcome = swipe.scroll(RowSwipe.Scroll(phase: .none, deltaX: -30), on: row)

        #expect(outcome == .pass)
        #expect(swipe.swipedRowID == nil)
    }

    @Test func touchingTheTrackpadKeepsTheRow() {
        swipeLeft(60, on: row)

        #expect(swipe.scroll(RowSwipe.Scroll(phase: .mayBegin), on: other) == .pass)
        #expect(swipe.swipedRowID == row)
    }

    // MARK: - Momentum

    @Test func theMomentumOfARowSwipeIsTakenFromTheList() {
        swipeLeft(60, on: row)

        let momentum = RowSwipe.Scroll(phase: .none, isMomentum: true, deltaX: -20)
        #expect(swipe.scroll(momentum, on: row) == .consume)
        #expect(swipe.scroll(momentum, on: other) == .consume)
        #expect(swipe.swipedRowID == row)
        #expect(swipe.offset(of: row) == RowSwipe.buttonWidth)
    }

    @Test func theMomentumOfAScrollGoesToTheList() {
        swipeLeft(60, on: row)
        gesture(on: row, steps: [(x: 0, y: 30)])

        let momentum = RowSwipe.Scroll(phase: .none, isMomentum: true, deltaY: 20)
        #expect(swipe.scroll(momentum, on: row) == .pass)
    }

    @Test func eventsWithoutAGestureGoToTheList() {
        #expect(swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -50), on: row) == .pass)
        #expect(swipe.scroll(RowSwipe.Scroll(phase: .ended), on: row) == .pass)
        #expect(swipe.offset(of: row) == 0)
    }

    // MARK: - One row at a time

    @Test func swipingAnotherRowClosesTheFirst() {
        swipeLeft(60, on: row)

        _ = swipe.scroll(RowSwipe.Scroll(phase: .began), on: other)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -20), on: other)

        #expect(swipe.offset(of: row) == 0)
        #expect(swipe.offset(of: other) == 20)

        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -40), on: other)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .ended), on: other)
        #expect(swipe.swipedRowID == other)
    }

    @Test func aGestureStaysWithTheRowItBeganOn() {
        _ = swipe.scroll(RowSwipe.Scroll(phase: .began), on: row)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -30), on: row)
        // The pointer moved over the next row meanwhile.
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -30), on: other)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .ended), on: other)

        #expect(swipe.swipedRowID == row)
        #expect(swipe.offset(of: other) == 0)
    }

    @Test func closingSlidesBackAndDropsTheGesture() {
        _ = swipe.scroll(RowSwipe.Scroll(phase: .began), on: row)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -100), on: row)

        swipe.close()

        #expect(swipe.offset(of: row) == 0)
        #expect(!swipe.isTracking(row))
        #expect(swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -100), on: row) == .pass)
        #expect(swipe.scroll(RowSwipe.Scroll(phase: .ended), on: row) == .pass)
        #expect(swipe.swipedRowID == nil)
    }

    // MARK: - Mouse

    @Test func aMouseDragSlidesTheRow() {
        swipe.drag(CGSize(width: -30, height: 1), on: row)
        swipe.drag(CGSize(width: -60, height: 2), on: row)
        #expect(swipe.offset(of: row) == 60)
        #expect(swipe.isTracking(row))

        #expect(swipe.endDrag() == nil)
        #expect(swipe.swipedRowID == row)
        #expect(swipe.offset(of: row) == RowSwipe.buttonWidth)
    }

    @Test func aLongMouseDragDeletes() {
        swipe.drag(CGSize(width: -RowSwipe.fullSwipeThreshold - 1, height: 0), on: row)

        #expect(swipe.endDrag() == row)
        #expect(swipe.swipedRowID == nil)
    }

    @Test func aVerticalMouseDragDoesNothing() {
        swipe.drag(CGSize(width: -2, height: 30), on: row)
        swipe.drag(CGSize(width: -80, height: 30), on: row)

        #expect(swipe.offset(of: row) == 0)
        #expect(swipe.endDrag() == nil)
        #expect(swipe.swipedRowID == nil)
    }

    // MARK: - Reduce Motion

    @Test func withReduceMotionTheButtonAppearsWholeInsteadOfSliding() {
        _ = swipe.scroll(RowSwipe.Scroll(phase: .began), on: row)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -(RowSwipe.holdThreshold - 1)), on: row)
        #expect(swipe.displayedOffset(of: row, reducesMotion: true) == 0)
        #expect(swipe.displayedOffset(of: row, reducesMotion: false) == RowSwipe.holdThreshold - 1)

        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -100), on: row)
        #expect(swipe.displayedOffset(of: row, reducesMotion: true) == RowSwipe.buttonWidth)

        _ = swipe.scroll(RowSwipe.Scroll(phase: .ended), on: row)
        #expect(swipe.displayedOffset(of: row, reducesMotion: true) == RowSwipe.buttonWidth)
        #expect(swipe.displayedOffset(of: other, reducesMotion: true) == 0)
    }
}
