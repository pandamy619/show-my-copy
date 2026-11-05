import AppKit
import SwiftUI

/// Creates the AppKit view that hosts `HistoryView`, so the window controller does not depend on SwiftUI.
enum HistoryContentFactory {
    @MainActor
    static func makeView(model: HistoryWindowModel, actions: HistoryViewActions) -> NSView {
        let view = HistoryView(
            model: model, onChoose: actions.choose, onClose: actions.close, onOpenSettings: actions.openSettings,
            onDrag: actions.drag, onCopyText: actions.copyText)
        let hostingView = NSHostingView(rootView: view)
        // The panel sets the size, not the SwiftUI content: the window controller switches between the compact and
        // the full size, and the hosting view follows through its autoresizing mask.
        hostingView.sizingOptions = []
        // The hidden title bar would otherwise count as a top safe-area inset and push the search field down.
        hostingView.safeAreaRegions = []
        hostingView.frame = NSRect(origin: .zero, size: HistoryPanelPlacement.fullSize)
        return hostingView
    }
}
