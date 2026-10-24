import AppKit
import Testing

@testable import ShowMyCopy

@MainActor
struct HistoryPanelTests {
    @Test func panelIsLeftOutOfScreenSharing() {
        let panel = HistoryPanel(contentRect: NSRect(origin: .zero, size: HistoryPanelPlacement.fullSize))
        #expect(panel.sharingType == NSWindow.SharingType.none)
    }

    @Test func titleBarShowsNothingOverTheSearchField() {
        // The content runs under the title bar, so the search field sits at the top edge. Nothing of the title bar
        // may show over it: no title, no buttons, no separator line.
        let panel = HistoryPanel(contentRect: NSRect(origin: .zero, size: HistoryPanelPlacement.fullSize))
        #expect(panel.titleVisibility == .hidden)
        #expect(panel.titlebarAppearsTransparent)
        #expect(panel.titlebarSeparatorStyle == .none)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            #expect(panel.standardWindowButton(button)?.isHidden ?? true)
        }
    }
}
