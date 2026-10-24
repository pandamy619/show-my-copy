import AppKit
import Observation

/// Shows the clipboard history in a floating panel over the app the user is working in.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    let model: HistoryWindowModel
    private let monitor: any PasteboardChangeTracking
    private let copier: any EntryCopying
    private let onOpenSettings: @MainActor () -> Void
    /// Read by tests to check the panel's frame.
    private(set) var panel: HistoryPanel?

    init(
        history: any HistoryStore,
        model: HistoryWindowModel? = nil,
        copier: any EntryCopying,
        monitor: any PasteboardChangeTracking,
        onOpenSettings: @escaping @MainActor () -> Void
    ) {
        self.model = model ?? HistoryWindowModel(history: history)
        self.copier = copier
        self.monitor = monitor
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // The monitor polls every half second. Catch up first, so a copy made just before the shortcut is listed
        // and selected.
        monitor.poll()
        model.prepareForPresentation()
        // Closing Settings hides the app to return focus to the previous app, and a hidden app shows no windows.
        // Unhide without activating, so the app the user copied from stays in front.
        NSApplication.shared.unhideWithoutActivation()
        // Size for what the list shows now, then place, so the first frame on screen is already right.
        let size = HistoryPanelPlacement.size(showsEntries: model.showsEntries)
        panel.setFrame(NSRect(origin: Self.origin(for: size), size: size), display: false)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        // A revealed password must not be on screen the next time the window opens.
        model.concealAll()
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Called when the user presses the history shortcut. Only a person at the awake, unlocked Mac can press it,
    /// so the monitor drops pause reasons left by a missed wake or unlock notification before the window opens.
    func shortcutPressed() {
        monitor.userIsActive()
        toggle()
    }

    /// Copies the entry back to the clipboard and closes the window. When the copy fails, the window stays open,
    /// so the user can try again or pick another entry.
    func choose(_ entry: ClipboardEntry) {
        // Return can arrive both as a key press and as a submit from the search field.
        guard isVisible else {
            return
        }
        guard copier.copy(entry) else {
            return
        }
        hide()
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // A click outside the panel or a switch to another app closes it.
        hide()
    }

    // MARK: - Private

    private func openSettings() {
        hide()
        onOpenSettings()
    }

    /// Watches whether the list has entries, for as long as the controller lives. A copy can arrive, the query can
    /// change or the history can be cleared from Settings while the panel is open.
    private func observeShowsEntries() {
        withObservationTracking {
            _ = model.showsEntries
        } onChange: { [weak self] in
            // Called once, before the new value is stored. Re-arm and resize after the change, on the main actor.
            Task { @MainActor [weak self] in
                self?.observeShowsEntries()
                self?.fitPanelToContent()
            }
        }
    }

    /// Compact with nothing to list, full size with entries. The top edge stays put, so the search field does not
    /// move. No animation: like Spotlight, the panel snaps to its new height.
    private func fitPanelToContent() {
        guard let panel, panel.isVisible else {
            // `show()` sizes the panel before it appears.
            return
        }
        let size = HistoryPanelPlacement.size(showsEntries: model.showsEntries)
        guard panel.frame.size != size else {
            return
        }
        let frame = HistoryPanelPlacement.frame(resizing: panel.frame, to: size, in: panel.screen?.visibleFrame)
        panel.setFrame(frame, display: true, animate: false)
    }

    private func makePanel() -> HistoryPanel {
        let size = HistoryPanelPlacement.fullSize
        let panel = HistoryPanel(contentRect: NSRect(origin: .zero, size: size))
        // A titled window adds the title bar height to the content rect. Keep the frame at the content size.
        panel.setFrame(NSRect(origin: .zero, size: size), display: false)
        panel.delegate = self
        panel.onCancel = { [weak self] in
            self?.hide()
        }

        // The background and the hosting view follow the panel's size as it switches between compact and full.
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.blendingMode = .behindWindow
        // The app is never active while the panel is shown, so keep the material from looking inactive.
        background.state = .active
        background.autoresizingMask = [.width, .height]

        let content = HistoryContentFactory.makeView(
            model: model,
            onChoose: { [weak self] entry in
                self?.choose(entry)
            },
            onClose: { [weak self] in
                self?.hide()
            },
            onOpenSettings: { [weak self] in
                self?.openSettings()
            }
        )
        content.frame = background.bounds
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)
        panel.contentView = background
        observeShowsEntries()
        return panel
    }

    /// The screen with the mouse pointer is the one the user is looking at.
    private static func origin(for size: CGSize) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            return .zero
        }
        return HistoryPanelPlacement.origin(for: size, in: visibleFrame)
    }
}
