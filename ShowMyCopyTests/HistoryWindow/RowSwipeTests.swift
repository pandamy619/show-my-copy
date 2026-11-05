import Foundation
import Testing

@testable import ShowMyCopy

/// A row slides left with a horizontal trackpad swipe, stays open as wide as its buttons past the hold threshold and
/// is deleted past the full-swipe threshold; vertical scrolling goes to the list. A mouse drag does not swipe: it drags
/// the entry out (`EntryDragTests`).
@MainActor
struct RowSwipeTests {
    private let swipe = RowSwipe()
    private let row = UUID()
    private let other = UUID()
    /// A row with three buttons, the most a row has.
    private let actionsWidth = RowSwipe.actionsWidth(buttonCount: 3)
    private var fullSwipe: CGFloat {
        RowSwipe.fullSwipeThreshold(actionsWidth: actionsWidth)
    }

    /// A trackpad gesture over `id`: began, one changed event per step and ended. Returns each event's outcome.
    @discardableResult
    private func gesture(
        on id: UUID, steps: [(x: CGFloat, y: CGFloat)], ends: RowSwipe.Phase = .ended
    ) -> [RowSwipe.Outcome] {
        var outcomes = [swipe.scroll(RowSwipe.Scroll(phase: .began), on: id, actionsWidth: actionsWidth)]
        for step in steps {
            outcomes.append(
                swipe.scroll(
                    RowSwipe.Scroll(phase: .changed, deltaX: step.x, deltaY: step.y), on: id, actionsWidth: actionsWidth
                ))
        }
        outcomes.append(swipe.scroll(RowSwipe.Scroll(phase: ends), on: id, actionsWidth: actionsWidth))
        return outcomes
    }

    /// A horizontal swipe of `distance` points to the left over `id`, in steps of 10 points and one for the rest.
    @discardableResult
    private func swipeLeft(_ distance: CGFloat, on id: UUID, ends: RowSwipe.Phase = .ended) -> [RowSwipe.Outcome] {
        let count = Int(distance / 10)
        var steps = Array(repeating: (x: CGFloat(-10), y: CGFloat(0)), count: count)
        let rest = distance - CGFloat(count) * 10
        if rest > 0 {
            steps.append((x: -rest, y: 0))
        }
        return gesture(on: id, steps: steps, ends: ends)
    }

    // MARK: - Thresholds

    @Test func thresholdsAreOrdered() {
        #expect(RowSwipe.axisLockDistance < RowSwipe.holdThreshold)
        #expect(RowSwipe.holdThreshold == RowSwipe.buttonWidth / 2)
        for count in 1...RowAction.maximumCount {
            let actionsWidth = RowSwipe.actionsWidth(buttonCount: count)
            #expect(RowSwipe.holdThreshold < actionsWidth)
            #expect(actionsWidth < RowSwipe.fullSwipeThreshold(actionsWidth: actionsWidth))
            #expect(RowSwipe.fullSwipeThreshold(actionsWidth: actionsWidth) < RowSwipe.maximumOffset)
        }
    }

    @Test func theOpenWidthIsTheSumOfTheButtons() {
        #expect(RowSwipe.actionsWidth(buttonCount: 1) == RowSwipe.buttonWidth)
        #expect(RowSwipe.actionsWidth(buttonCount: 3) == 3 * RowSwipe.buttonWidth)
    }

    @Test func aRowWithFewerButtonsOpensNarrowerAndDeletesSooner() {
        let narrow = RowSwipe.actionsWidth(buttonCount: 2)
        let full = RowSwipe.fullSwipeThreshold(actionsWidth: narrow)

        _ = swipe.scroll(RowSwipe.Scroll(phase: .began), on: row, actionsWidth: narrow)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -(full - 1)), on: row, actionsWidth: narrow)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .ended), on: row, actionsWidth: narrow)
        #expect(swipe.offset(of: row) == narrow)
        #expect(swipe.displayedOffset(of: row, reducesMotion: true) == narrow)

        _ = swipe.scroll(RowSwipe.Scroll(phase: .began), on: other, actionsWidth: narrow)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -full), on: other, actionsWidth: narrow)
        #expect(swipe.scroll(RowSwipe.Scroll(phase: .ended), on: other, actionsWidth: narrow) == .delete(other))
    }

    @Test func theRowFollowsTheFingersWhileSwiping() {
        _ = swipe.scroll(RowSwipe.Scroll(phase: .began), on: row, actionsWidth: actionsWidth)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -30), on: row, actionsWidth: actionsWidth)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -25), on: row, actionsWidth: actionsWidth)

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

    @Test func aSwipePastTheHoldThresholdKeepsTheRowOpen() {
        swipeLeft(RowSwipe.holdThreshold + 10, on: row)

        #expect(swipe.offset(of: row) == actionsWidth)
        #expect(swipe.swipedRowID == row)
        #expect(!swipe.isTracking(row))
    }

    @Test func aSwipeJustShortOfTheFullSwipeKeepsTheRowOpen() {
        let outcomes = swipeLeft(fullSwipe - 10, on: row)

        #expect(!outcomes.contains(.delete(row)))
        #expect(swipe.swipedRowID == row)
        #expect(swipe.offset(of: row) == actionsWidth)
    }

    @Test func aFullSwipeDeletes() {
        let outcomes = swipeLeft(fullSwipe, on: row)

        #expect(outcomes.last == .delete(row))
        #expect(swipe.swipedRowID == nil)
        #expect(swipe.offset(of: row) == 0)
    }

    @Test func aCancelledFullSwipeDoesNotDelete() {
        let outcomes = swipeLeft(fullSwipe + 20, on: row, ends: .cancelled)

        #expect(!outcomes.contains(.delete(row)))
        #expect(swipe.swipedRowID == row)
    }

    @Test func theRowStopsAtTheMaximumAndNeverSlidesRight() {
        _ = swipe.scroll(RowSwipe.Scroll(phase: .began), on: row, actionsWidth: actionsWidth)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -1000), on: row, actionsWidth: actionsWidth)
        #expect(swipe.offset(of: row) == RowSwipe.maximumOffset)

        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: 2000), on: row, actionsWidth: actionsWidth)
        #expect(swipe.offset(of: row) == 0)
    }

    @Test func swipingRightClosesTheRow() {
        swipeLeft(60, on: row)
        #expect(swipe.swipedRowID == row)

        gesture(on: row, steps: [(x: 30, y: 0), (x: actionsWidth - 30, y: 0)])

        #expect(swipe.swipedRowID == nil)
        #expect(swipe.offset(of: row) == 0)
    }

    @Test func anOpenRowSlidesOnFromThere() {
        swipeLeft(60, on: row)

        _ = swipe.scroll(RowSwipe.Scroll(phase: .began), on: row, actionsWidth: actionsWidth)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -10), on: row, actionsWidth: actionsWidth)

        #expect(swipe.offset(of: row) == actionsWidth + 10)
    }

    // MARK: - Axis lock

    @Test func undecidedMovementGoesToTheList() {
        let outcome = swipe.scroll(
            RowSwipe.Scroll(phase: .began, deltaX: -2, deltaY: 1), on: row, actionsWidth: actionsWidth)

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

        let outcome = swipe.scroll(RowSwipe.Scroll(phase: .none, deltaX: -30), on: row, actionsWidth: actionsWidth)

        #expect(outcome == .pass)
        #expect(swipe.swipedRowID == nil)
    }

    @Test func touchingTheTrackpadKeepsTheRow() {
        swipeLeft(60, on: row)

        #expect(swipe.scroll(RowSwipe.Scroll(phase: .mayBegin), on: other, actionsWidth: actionsWidth) == .pass)
        #expect(swipe.swipedRowID == row)
    }

    // MARK: - Momentum

    @Test func theMomentumOfARowSwipeIsTakenFromTheList() {
        swipeLeft(60, on: row)

        let momentum = RowSwipe.Scroll(phase: .none, isMomentum: true, deltaX: -20)
        #expect(swipe.scroll(momentum, on: row, actionsWidth: actionsWidth) == .consume)
        #expect(swipe.scroll(momentum, on: other, actionsWidth: actionsWidth) == .consume)
        #expect(swipe.swipedRowID == row)
        #expect(swipe.offset(of: row) == actionsWidth)
    }

    @Test func theMomentumOfAScrollGoesToTheList() {
        swipeLeft(60, on: row)
        gesture(on: row, steps: [(x: 0, y: 30)])

        let momentum = RowSwipe.Scroll(phase: .none, isMomentum: true, deltaY: 20)
        #expect(swipe.scroll(momentum, on: row, actionsWidth: actionsWidth) == .pass)
    }

    @Test func eventsWithoutAGestureGoToTheList() {
        #expect(
            swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -50), on: row, actionsWidth: actionsWidth) == .pass)
        #expect(swipe.scroll(RowSwipe.Scroll(phase: .ended), on: row, actionsWidth: actionsWidth) == .pass)
        #expect(swipe.offset(of: row) == 0)
    }

    // MARK: - One row at a time

    @Test func swipingAnotherRowClosesTheFirst() {
        swipeLeft(60, on: row)

        _ = swipe.scroll(RowSwipe.Scroll(phase: .began), on: other, actionsWidth: actionsWidth)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -20), on: other, actionsWidth: actionsWidth)

        #expect(swipe.offset(of: row) == 0)
        #expect(swipe.offset(of: other) == 20)

        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -40), on: other, actionsWidth: actionsWidth)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .ended), on: other, actionsWidth: actionsWidth)
        #expect(swipe.swipedRowID == other)
    }

    @Test func aGestureStaysWithTheRowItBeganOn() {
        _ = swipe.scroll(RowSwipe.Scroll(phase: .began), on: row, actionsWidth: actionsWidth)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -30), on: row, actionsWidth: actionsWidth)
        // The pointer moved over the next row meanwhile.
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -30), on: other, actionsWidth: actionsWidth)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .ended), on: other, actionsWidth: actionsWidth)

        #expect(swipe.swipedRowID == row)
        #expect(swipe.offset(of: other) == 0)
    }

    @Test func closingSlidesBackAndDropsTheGesture() {
        _ = swipe.scroll(RowSwipe.Scroll(phase: .began), on: row, actionsWidth: actionsWidth)
        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -100), on: row, actionsWidth: actionsWidth)

        swipe.close()

        #expect(swipe.offset(of: row) == 0)
        #expect(!swipe.isTracking(row))
        #expect(
            swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -100), on: row, actionsWidth: actionsWidth) == .pass)
        #expect(swipe.scroll(RowSwipe.Scroll(phase: .ended), on: row, actionsWidth: actionsWidth) == .pass)
        #expect(swipe.swipedRowID == nil)
    }

    // MARK: - Reduce Motion

    @Test func withReduceMotionTheButtonsAppearInsteadOfSliding() {
        _ = swipe.scroll(RowSwipe.Scroll(phase: .began), on: row, actionsWidth: actionsWidth)
        _ = swipe.scroll(
            RowSwipe.Scroll(phase: .changed, deltaX: -(RowSwipe.holdThreshold - 1)), on: row, actionsWidth: actionsWidth
        )
        #expect(swipe.displayedOffset(of: row, reducesMotion: true) == 0)
        #expect(swipe.displayedOffset(of: row, reducesMotion: false) == RowSwipe.holdThreshold - 1)

        _ = swipe.scroll(RowSwipe.Scroll(phase: .changed, deltaX: -100), on: row, actionsWidth: actionsWidth)
        #expect(swipe.displayedOffset(of: row, reducesMotion: true) == actionsWidth)

        _ = swipe.scroll(RowSwipe.Scroll(phase: .ended), on: row, actionsWidth: actionsWidth)
        #expect(swipe.displayedOffset(of: row, reducesMotion: true) == actionsWidth)
        #expect(swipe.displayedOffset(of: other, reducesMotion: true) == 0)
    }
}
