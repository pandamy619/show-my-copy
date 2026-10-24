import AppKit
import Testing

@testable import ShowMyCopy

@MainActor
struct HistoryPanelTests {
    @Test func panelIsLeftOutOfScreenSharing() {
        let panel = HistoryPanel(contentRect: NSRect(origin: .zero, size: HistoryPanelPlacement.fullSize))
        #expect(panel.sharingType == NSWindow.SharingType.none)
    }
}
