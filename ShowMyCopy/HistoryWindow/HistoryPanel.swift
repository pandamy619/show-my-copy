import AppKit

/// A floating panel that takes keyboard input without activating the app, so the app the user copied from
/// stays in front.
final class HistoryPanel: NSPanel {
    /// Called when the user presses Escape and no view handled it.
    var onCancel: (@MainActor () -> Void)?

    convenience init(contentRect: NSRect) {
        self.init(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isFloatingPanel = true
        level = .floating
        // .canJoinAllSpaces already shows the panel on the current Space. Combining it with .moveToActiveSpace
        // raises an exception.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Where the history panel appears: centered horizontally in the upper part of a screen, like Spotlight.
enum HistoryPanelPlacement {
    static let size = CGSize(width: 480, height: 420)

    /// Fraction of the visible screen height between its top edge and the panel's top edge.
    static let topOffsetFraction: CGFloat = 0.2

    static func origin(for size: CGSize, in visibleFrame: CGRect) -> CGPoint {
        let x = visibleFrame.midX - size.width / 2
        let top = visibleFrame.maxY - visibleFrame.height * topOffsetFraction
        var y = top - size.height
        // Keep the whole panel on screen when the screen is short.
        y = max(y, visibleFrame.minY)
        y = min(y, visibleFrame.maxY - size.height)
        return CGPoint(x: max(x, visibleFrame.minX), y: y)
    }
}
