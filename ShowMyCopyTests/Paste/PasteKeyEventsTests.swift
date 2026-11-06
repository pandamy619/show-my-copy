import Testing

@testable import ShowMyCopy

struct PasteKeyEventsTests {
    private let dvorakV: UInt16 = 47

    /// A real ⌘V: ⌘ down, V down and up with ⌘ and "v", ⌘ up.
    @Test func standardPressesCommandAroundV() {
        let events = PastePostingStyle.standard.events(pasteKeyCode: PasteKey.ansiV)

        #expect(
            events == [
                PasteKeyEvent(kind: .flagsChanged, keyCode: PasteKey.leftCommand, holdsCommand: true, text: nil),
                PasteKeyEvent(kind: .keyDown, keyCode: PasteKey.ansiV, holdsCommand: true, text: "v"),
                PasteKeyEvent(kind: .keyUp, keyCode: PasteKey.ansiV, holdsCommand: true, text: "v"),
                PasteKeyEvent(kind: .flagsChanged, keyCode: PasteKey.leftCommand, holdsCommand: false, text: nil),
            ])
    }

    @Test func standardPostsToTheSession() {
        #expect(PastePostingStyle.standard.tap == .session)
        #expect(PastePostingStyle.standard.pressesCommandKey)
        #expect(PastePostingStyle.standard.carriesText)
    }

    /// As Maccy and Clipy post it.
    @Test func withoutTheCommandKeyOnlyVGoesDownAndUpWithCommandSet() {
        let style = PastePostingStyle(pressesCommandKey: false, carriesText: false, tap: .session)

        #expect(
            style.events(pasteKeyCode: PasteKey.ansiV) == [
                PasteKeyEvent(kind: .keyDown, keyCode: PasteKey.ansiV, holdsCommand: true, text: nil),
                PasteKeyEvent(kind: .keyUp, keyCode: PasteKey.ansiV, holdsCommand: true, text: nil),
            ])
    }

    /// The key is the one `PasteKey` found, such as Dvorak's V; the text stays "v" and ⌘ stays the left ⌘ key.
    @Test func usesTheKeyItIsGiven() {
        let events = PastePostingStyle.standard.events(pasteKeyCode: dvorakV)

        #expect(events.filter { $0.kind != .flagsChanged }.allSatisfy { $0.keyCode == dvorakV && $0.text == "v" })
        #expect(events.filter { $0.kind == .flagsChanged }.allSatisfy { $0.keyCode == PasteKey.leftCommand })
    }

    /// Whatever the style, the last event lets ⌘ go, every V down has its V up, and the ⌘ key carries no text.
    @Test func neverLeavesCommandDown() {
        for pressesCommandKey in [false, true] {
            for carriesText in [false, true] {
                let style = PastePostingStyle(
                    pressesCommandKey: pressesCommandKey, carriesText: carriesText, tap: .hid)
                let events = style.events(pasteKeyCode: PasteKey.ansiV)

                #expect(events.filter { $0.kind == .keyDown }.count == 1)
                #expect(events.filter { $0.kind == .keyUp }.count == 1)
                #expect(events.firstIndex { $0.kind == .keyDown } ?? 0 < events.firstIndex { $0.kind == .keyUp } ?? 0)
                #expect(events.filter { $0.kind == .flagsChanged }.allSatisfy { $0.text == nil })
                if pressesCommandKey {
                    #expect(events.last?.kind == .flagsChanged)
                    #expect(events.last?.holdsCommand == false)
                } else {
                    #expect(events.last?.kind == .keyUp)
                }
            }
        }
    }

    @Test func standardTuningIsTheStandardTimingAndStyle() {
        #expect(PasteTuning.standard == PasteTuning(timing: .standard, style: .standard))
    }
}

struct PasteTimingTests {
    /// Long enough for Chromium and Electron apps to make their window key and focus the field again, short enough
    /// that the paste still feels immediate.
    @Test func standardValues() {
        let timing = PasteTiming.standard
        #expect(timing.pollInterval == .milliseconds(10))
        #expect(timing.longestWaitForWindow == .milliseconds(250))
        #expect(timing.settleDelay == .milliseconds(150))
    }

    @Test func aPasteWaitsAtMostFourTenthsOfASecond() {
        #expect(PasteTiming.standard.longestWait == .milliseconds(400))
    }

    /// The checks fit the longest wait exactly, so the wait never runs past it.
    @Test func checksFitTheWaitForTheWindow() {
        let timing = PasteTiming.standard
        let checks = timing.longestWaitForWindow / timing.pollInterval
        #expect(checks == checks.rounded())
        #expect(checks >= 10)
    }
}
