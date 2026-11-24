import KeyboardShortcuts
import Testing

@testable import ShowMyCopy

/// The names the app's global shortcuts are registered under, one per `GlobalShortcut`.
struct GlobalShortcutTests {
    @Test func eachShortcutHasItsOwnName() {
        let names = GlobalShortcut.allCases.map(KeyboardShortcuts.Name.name(for:))

        #expect(Set(names.map(\.rawValue)).count == GlobalShortcut.allCases.count)
        #expect(KeyboardShortcuts.Name.name(for: .showHistory) == .toggleHistoryWindow)
        #expect(KeyboardShortcuts.Name.name(for: .showCodes) == .showCodes)
    }

    @Test func onlyTheHistoryShortcutHasKeysByDefault() {
        // A global shortcut takes its keys from every app: codes get one only when the user records it.
        #expect(KeyboardShortcuts.Name.toggleHistoryWindow.initialShortcut != nil)
        #expect(KeyboardShortcuts.Name.showCodes.initialShortcut == nil)
    }
}
