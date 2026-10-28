import AppKit

/// A floating panel that takes keyboard input without activating the app, so the app the user copied from
/// stays in front.
final class HistoryPanel: NSPanel {
    /// Called when the user presses Escape and no view handled it.
    var onCancel: (@MainActor () -> Void)?
    /// Called with ⌘⌫ and ⌘Z (`commandKey(characters:modifiers:)`). Returns whether it handled the key; when it did
    /// not, the key goes on as usual, for example to Undo in the Edit menu, which undoes typing in the search field.
    var onCommandKey: (@MainActor (HistoryWindowModel.Key) -> Bool)?

    convenience init(contentRect: NSRect) {
        self.init(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // The content runs under the hidden title bar, so the search field sits at the top edge. No line under it.
        titlebarSeparatorStyle = .none
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

    /// Key presses with ⌘ come here before the search field gets them and before the main menu does, so ⌘Z can
    /// bring back a deleted entry instead of undoing typing.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let key = Self.commandKey(characters: event.characters, modifiers: event.modifierFlags),
            onCommandKey?(key) == true
        else {
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// The history window's key for a key press with ⌘ and no other modifier: ⌘⌫ (Delete, not Forward Delete) and
    /// ⌘Z. Nil for anything else, such as ⇧⌘Z or ⌥⌘⌫. `characters` are those the keyboard layout gives with ⌘,
    /// which are Latin letters also on layouts such as Russian, as for menu shortcuts.
    nonisolated static func commandKey(
        characters: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> HistoryWindowModel.Key? {
        guard modifiers.intersection([.command, .shift, .option, .control]) == .command else {
            return nil
        }
        switch characters?.lowercased() {
        case Self.deleteCharacter:
            return .delete
        case "z":
            return .undo
        default:
            return nil
        }
    }

    /// What the Delete (Backspace) key types: `NSDeleteCharacter`.
    private nonisolated static let deleteCharacter = "\u{7F}"
}

/// Where the history panel appears and how big it is: centered horizontally in the upper part of a screen, like
/// Spotlight. With nothing to list, the panel holds only the search bar and one message row; it grows downward when
/// entries appear, so the search field never moves.
enum HistoryPanelPlacement {
    /// The size with entries listed.
    static let fullSize = CGSize(width: 480, height: 420)

    /// Heights of the rows `HistoryView` lays out. The compact panel is exactly these rows tall.
    /// The search bar's height leaves about as much space above and below the search field as its 14 pt side
    /// padding, like Spotlight.
    static let searchBarHeight: CGFloat = 48
    static let dividerHeight: CGFloat = 1
    static let messageRowHeight: CGFloat = 44

    /// The content height with nothing to list: the search bar, the divider under it and one message row.
    static let compactHeight = searchBarHeight + dividerHeight + messageRowHeight

    /// Fraction of the visible screen height between its top edge and the panel's top edge.
    static let topOffsetFraction: CGFloat = 0.2

    /// The panel's frame size. The content starts at the panel's top edge (`HistoryContentFactory` turns off the
    /// title bar's safe area), so the compact panel is exactly its rows tall.
    static func size(showsEntries: Bool) -> CGSize {
        showsEntries ? fullSize : CGSize(width: fullSize.width, height: compactHeight)
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
