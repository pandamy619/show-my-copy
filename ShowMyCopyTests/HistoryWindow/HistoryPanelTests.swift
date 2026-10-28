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

    @Test func commandKeysReachTheHistoryWindow() {
        #expect(HistoryPanel.commandKey(characters: "\u{7F}", modifiers: .command) == .delete)
        #expect(HistoryPanel.commandKey(characters: "z", modifiers: .command) == .undo)
        // Caps Lock on.
        #expect(HistoryPanel.commandKey(characters: "Z", modifiers: [.command, .capsLock]) == .undo)
        #expect(HistoryPanel.commandKey(characters: "\u{7F}", modifiers: [.command, .capsLock]) == .delete)
    }

    private nonisolated static let otherKeys: [(String, NSEvent.ModifierFlags)] = [
        // Delete without ⌘ edits the search text.
        ("\u{7F}", []),
        // ⌥⌘⌫, ⇧⌘Z (Redo), ⌃⌘Z.
        ("\u{7F}", [.command, .option]),
        ("z", [.command, .shift]),
        ("z", [.command, .control]),
        // Forward Delete.
        ("\u{F728}", .command),
        ("a", .command),
    ]

    @Test(arguments: otherKeys)
    func otherKeysGoOnAsUsual(characters: String, modifiers: NSEvent.ModifierFlags) {
        #expect(HistoryPanel.commandKey(characters: characters, modifiers: modifiers) == nil)
    }

    @Test func aKeyEquivalentWithoutCharactersIsNotTheWindows() {
        #expect(HistoryPanel.commandKey(characters: nil, modifiers: .command) == nil)
    }
}
