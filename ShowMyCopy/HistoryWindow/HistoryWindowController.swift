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
    /// The resize scheduled by the last change of what the list shows. Tests await it instead of guessing when the
    /// main actor gets to it.
    private(set) var pendingResize: Task<Void, Never>?

    init(
        model: HistoryWindowModel,
        copier: any EntryCopying,
        monitor: any PasteboardChangeTracking,
        onOpenSettings: @escaping @MainActor () -> Void
    ) {
        self.model = model
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
        monitor.historyWindowOpened(true)
    }

    func hide() {
        let wasVisible = isVisible
        panel?.orderOut(nil)
        if wasVisible {
            monitor.historyWindowOpened(false)
        }
        // A revealed password must not be on screen the next time the window opens.
        model.concealAll()
        // Drop the preview, and with it a full image, while the window is closed.
        model.preview.close()
        // Undo works only while the window is open: a deleted entry's files go now.
        model.finishDeleting()
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

    /// Called when the user asks for the history from outside the app, such as with the Control Center button. Like
    /// the shortcut, only a person at the Mac can ask. Unlike the shortcut, it only opens the window: an open window
    /// stays open, with its search and selection.
    func openRequested() {
        monitor.userIsActive()
        guard !isVisible else {
            return
        }
        show()
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

    /// ⌘⌫ and ⌘Z, which reach the panel as key equivalents before the search field or the Edit menu sees them.
    /// Returns false for a key the model leaves to the search field, such as ⌘Z with nothing to bring back, which
    /// then undoes typing.
    func handleCommandKey(_ key: HistoryWindowModel.Key) -> Bool {
        guard isVisible else {
            return false
        }
        switch model.handleKey(key, isCaretAtEnd: true) {
        case .handled:
            return true
        case .ignored:
            return false
        case .choose(let entry):
            choose(entry)
            return true
        case .close:
            hide()
            return true
        }
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
            // Called once, before the new value is stored, by the code that changes it. The model and the history
            // are main-actor types, so that is the main actor. Re-arm and resize after the change.
            MainActor.assumeIsolated {
                self?.scheduleResize()
            }
        }
    }

    private func scheduleResize() {
        pendingResize = Task { @MainActor [weak self] in
            self?.observeShowsEntries()
            self?.fitPanelToContent()
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
        panel.onCommandKey = { [weak self] key in
            self?.handleCommandKey(key) ?? false
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
