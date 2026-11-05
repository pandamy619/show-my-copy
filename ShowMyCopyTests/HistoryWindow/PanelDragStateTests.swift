import Testing

@testable import ShowMyCopy

/// The history panel stays open while an entry is dragged out of it, closes when it is dropped in another app and
/// stays open when the drag is cancelled.
struct PanelDragStateTests {
    @Test func withoutADragLosingKeyFocusCloses() {
        var state = PanelDragState()

        let closes = state.panelResignedKey()
        #expect(closes)
    }

    @Test func whileDraggingLosingKeyFocusDoesNotClose() {
        var state = PanelDragState()
        state.began()

        let closesFirst = state.panelResignedKey()
        #expect(!closesFirst)
        let closesAgain = state.panelResignedKey()
        #expect(!closesAgain)
        #expect(state.isDragging)
    }

    @Test func aDropCloses() {
        var state = PanelDragState()
        state.began()

        let ending = state.ended(dropped: true)
        #expect(ending == .close)
        #expect(!state.isDragging)
    }

    @Test func aDropAfterLosingKeyFocusCloses() {
        var state = PanelDragState()
        state.began()
        _ = state.panelResignedKey()

        let ending = state.ended(dropped: true)
        #expect(ending == .close)
    }

    @Test func aCancelledDragStaysOpen() {
        var state = PanelDragState()
        state.began()

        let ending = state.ended(dropped: false)
        #expect(ending == .stayOpen(restoresKey: false))
    }

    @Test func aCancelledDragThatLostKeyFocusTakesItBack() {
        var state = PanelDragState()
        state.began()
        _ = state.panelResignedKey()

        let ending = state.ended(dropped: false)
        #expect(ending == .stayOpen(restoresKey: true))
    }

    @Test func afterTheDragLosingKeyFocusClosesAgain() {
        var state = PanelDragState()
        state.began()
        _ = state.ended(dropped: false)

        let closes = state.panelResignedKey()
        #expect(closes)
    }

    @Test func aDragThatEndsAfterAResetChangesNothing() {
        var state = PanelDragState()
        state.began()
        state.reset()

        let ending = state.ended(dropped: true)
        #expect(ending == .ignore)
        let closes = state.panelResignedKey()
        #expect(closes)
    }

    @Test func anEndWithoutABeginningChangesNothing() {
        var state = PanelDragState()

        let ending = state.ended(dropped: true)
        #expect(ending == .ignore)
        let secondEnding = state.ended(dropped: false)
        #expect(secondEnding == .ignore)
    }

    @Test func aNewDragForgetsThatTheLastOneLostKeyFocus() {
        var state = PanelDragState()
        state.began()
        _ = state.panelResignedKey()
        state.began()

        let ending = state.ended(dropped: false)
        #expect(ending == .stayOpen(restoresKey: false))
    }
}
