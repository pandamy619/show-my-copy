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
        // The panel shows clipboard contents, so keep it out of screen sharing, screenshots and recordings.
        // This is the documented opt-out. Capture through ScreenCaptureKit on newer macOS versions may still
        // include the window.
        sharingType = NSWindow.SharingType.none
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

/// Where the history panel appears and how big it is: centered horizontally in the upper part of a screen, like
/// Spotlight. With nothing to list, the panel holds only the search bar and one message row; it grows downward when
/// entries appear, so the search field never moves.
enum HistoryPanelPlacement {
    /// The size with entries listed.
    static let fullSize = CGSize(width: 480, height: 420)

    /// Heights of the rows `HistoryView` lays out. The compact panel is exactly these rows tall.
    static let searchBarHeight: CGFloat = 52
    static let dividerHeight: CGFloat = 1
    static let messageRowHeight: CGFloat = 44

    /// The content height with nothing to list: the search bar, the divider under it and one message row.
    static let compactHeight = searchBarHeight + dividerHeight + messageRowHeight

    /// Fraction of the visible screen height between its top edge and the panel's top edge.
    static let topOffsetFraction: CGFloat = 0.2

    /// The panel's frame size. `topInset` is the part of the panel the transparent title bar keeps the content out
    /// of; the compact panel adds it, so its rows are not cut off.
    static func size(showsEntries: Bool, topInset: CGFloat = 0) -> CGSize {
        showsEntries ? fullSize : CGSize(width: fullSize.width, height: compactHeight + max(topInset, 0))
    }

    static func origin(for size: CGSize, in visibleFrame: CGRect) -> CGPoint {
        let x = visibleFrame.midX - size.width / 2
        let top = visibleFrame.maxY - visibleFrame.height * topOffsetFraction
        let y = clampedY(top - size.height, height: size.height, in: visibleFrame)
        return CGPoint(x: max(x, visibleFrame.minX), y: y)
    }

    /// The frame for `size` that keeps the top and left edges of `current`, so the search field stays where it is.
    /// Moves up only as far as needed to keep the panel above the bottom of `visibleFrame`.
    static func frame(resizing current: CGRect, to size: CGSize, in visibleFrame: CGRect?) -> CGRect {
        var y = current.maxY - size.height
        if let visibleFrame {
            y = clampedY(y, height: size.height, in: visibleFrame)
        }
        return CGRect(origin: CGPoint(x: current.minX, y: y), size: size)
    }

    /// Keeps the whole panel on screen. When the screen is shorter than the panel, the top edge, with the search
    /// field, stays on screen.
    private static func clampedY(_ y: CGFloat, height: CGFloat, in visibleFrame: CGRect) -> CGFloat {
        min(max(y, visibleFrame.minY), visibleFrame.maxY - height)
    }
}
