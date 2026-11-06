import AppKit
import Observation

/// Shows the clipboard history in a floating panel over the app the user is working in.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    let model: HistoryWindowModel
    private let monitor: any PasteboardChangeTracking
    private let copier: any EntryCopying
    private let paster: any EntryPasting
    /// Shows Settings on a page, or on the page they show with nil.
    private let onOpenSettings: @MainActor (SettingsSection?) -> Void
    /// Made when the window first opens and kept for the next time.
    private(set) var panel: HistoryPanel?
    /// The resize scheduled by the last change of what the list shows. Tests await it instead of guessing when the
    /// main actor gets to it.
    private(set) var pendingResize: Task<Void, Never>?
    /// Keeps the panel open while the user drags an entry out of it.
    private var drag = PanelDragState()

    init(
        model: HistoryWindowModel,
        copier: any EntryCopying,
        paster: any EntryPasting,
        monitor: any PasteboardChangeTracking,
        onOpenSettings: @escaping @MainActor (SettingsSection?) -> Void
    ) {
        self.model = model
        self.copier = copier
        self.paster = paster
        self.monitor = monitor
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// Whether the panel is off screen as far as the window server knows: not visible, not key, and not among the
    /// app's windows on screen, which it still is while it fades out. The paster waits for this before it sends ⌘V.
    var isGoneFromScreen: Bool {
        guard let panel else {
            return true
        }
        guard !panel.isVisible, !panel.isKeyWindow else {
            return false
        }
        let onScreen = NSWindow.windowNumbers(options: []) ?? []
        return !onScreen.contains { $0.intValue == panel.windowNumber }
    }

    func show() {
        drag.reset()
        let panel = panel ?? makePanel()
        self.panel = panel
        // The monitor polls every half second. Catch up first, so a copy made just before the shortcut is listed
        // and selected.
        monitor.poll()
        model.prepareForPresentation()
        // A paste that only copied since the window was last open is told about once, now.
        model.pasteHint = paster.takeFallbackHint()
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
        // A drag that ends after this leaves the next window alone.
        drag.reset()
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
        model.pasteHint = nil
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

    /// Copies the entry back to the clipboard and closes the window, then, when `pastes` is true, pastes it into the
    /// app in front (`EntryPasting`). When the copy fails, the window stays open, so the user can try again or pick
    /// another entry, and nothing is pasted.
    ///
    /// The window closes before the paste: it has key focus, and ⌘V must reach the app the user was working in.
    func choose(_ entry: ClipboardEntry, pastes: Bool) {
        // Return can arrive both as a key press and as a submit from the search field.
        guard isVisible else {
            return
        }
        guard let changeCount = copier.copy(entry) else {
            return
        }
        hide()
        if pastes {
            paster.paste(copiedAt: changeCount) { [weak self] in
                self?.isGoneFromScreen ?? true
            }
        }
    }

    /// Copies text the user selected in the window, such as a file's folder in the preview, without recording it
    /// (`EntryCopying.copyText(_:)`). The window stays open: the user copied a detail, not an entry.
    func copySelectedText(_ text: String) {
        copier.copyText(text)
    }

    /// ⌘⌫, ⌘Z and ⌘P, which reach the panel as key equivalents before the search field or the main menu sees them.
    /// Returns false for a key the model leaves to the search field, such as ⌘Z with nothing to bring back, which
    /// then undoes typing. ⌘P is always handled while the window is open, so it never prints.
    func handleCommandKey(_ key: HistoryWindowModel.Key) -> Bool {
        guard isVisible else {
            return false
        }
        switch model.handleKey(key, isCaretAtEnd: true) {
        case .handled:
            return true
        case .ignored:
            return false
        case .choose(let entry, let pastes):
            choose(entry, pastes: pastes)
            return true
        case .close:
            hide()
            return true
        }
    }

    /// A row is being dragged out of the window (`PanelDragState`). The panel stays open during the drag and closes
    /// when the entry is dropped in another app, which then has it as if it were pasted there; the clipboard and the
    /// history are left as they are. A cancelled drag leaves it open.
    func rowDrag(_ event: RowDragEvent) {
        switch event {
        case .began:
            model.swipe.close()
            drag.began()
        case .ended(let dropped):
            switch drag.ended(dropped: dropped) {
            case .close:
                hide()
            case .stayOpen(let restoresKey):
                if restoresKey, isVisible {
                    panel?.makeKeyAndOrderFront(nil)
                }
            case .ignore:
                break
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // A click outside the panel or a switch to another app closes it, but not while the user drags an entry out.
        if drag.panelResignedKey() {
            hide()
        }
    }

    // MARK: - Private

    private func openSettings(_ section: SettingsSection?) {
        hide()
        onOpenSettings(section)
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

        let actions = HistoryViewActions(
            choose: { [weak self] entry, pastes in
                self?.choose(entry, pastes: pastes)
            },
            close: { [weak self] in
                self?.hide()
            },
            openSettings: { [weak self] section in
                self?.openSettings(section)
            },
            drag: { [weak self] event in
                self?.rowDrag(event)
            },
            copyText: { [weak self] text in
                self?.copySelectedText(text)
            }
        )
        let content = HistoryContentFactory.makeView(model: model, actions: actions)
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
