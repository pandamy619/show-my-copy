import AppKit

/// Shows the clipboard history in a floating panel over the app the user is working in.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    let model: HistoryWindowModel
    private let monitor: ClipboardMonitor
    private let copier: EntryCopier
    private let onOpenSettings: @MainActor () -> Void
    private var panel: HistoryPanel?

    init(
        history: ClipboardHistory,
        model: HistoryWindowModel? = nil,
        pasteboard: any PasteboardWriting,
        monitor: ClipboardMonitor,
        onOpenSettings: @escaping @MainActor () -> Void
    ) {
        self.model = model ?? HistoryWindowModel(history: history)
        self.monitor = monitor
        self.copier = EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor)
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
        panel.setFrameOrigin(Self.origin(for: panel.frame.size))
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
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

    private func makePanel() -> HistoryPanel {
        let panel = HistoryPanel(contentRect: NSRect(origin: .zero, size: HistoryPanelPlacement.size))
        // A titled window adds the title bar height to the content rect. Keep the frame at the content size.
        panel.setFrame(NSRect(origin: .zero, size: HistoryPanelPlacement.size), display: false)
        panel.delegate = self
        panel.onCancel = { [weak self] in
            self?.hide()
        }

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: HistoryPanelPlacement.size))
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
