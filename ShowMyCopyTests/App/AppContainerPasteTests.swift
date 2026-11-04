import Foundation
import Testing

@testable import ShowMyCopy

/// Pasting after choosing an entry as the container wires it: off and never asked for until the user turns it on.
@MainActor
struct AppContainerPasteTests {
    private let pasteboard = FakePasteboard()
    private let keystrokes = FakePasteKeystrokes()
    private let systemSettings = FakeAccessibilitySettings()
    private let textEdit = SourceApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")

    private func withContainer(_ body: (AppContainer) async throws -> Void) async throws {
        try await ContainerFactory.withDefaults { defaults in
            let services = ContainerFactory.services(
                pasteboard: pasteboard, frontmostApp: { [textEdit] in textEdit },
                paste: .fake(keystrokes, systemSettings: systemSettings))
            // On the container's clock, so the age limit keeps entries recorded at its time.
            let store = InMemoryHistoryStore(now: { ContainerFactory.date })
            let container = AppContainer(history: .unsaved(store), services: services, defaults: defaults)
            defer { container.monitor.stop() }
            try await body(container)
        }
    }

    @Test func launchingNeverAsksForPermissionToPaste() async throws {
        try await withContainer { container in
            container.start()
            container.showSettingsOnFirstLaunch()

            #expect(!container.settings.paste.isOn)
            #expect(keystrokes.requestCount == 0)
            #expect(keystrokes.postCount == 0)
            #expect(systemSettings.openCount == 0)
        }
    }

    /// Settings → General opens the System Settings the services give, so the app opens the real Privacy & Security.
    @Test func settingsOpenTheSystemSettingsOfTheServices() async throws {
        try await withContainer { container in
            container.start()
            container.settings.paste.setOn(true)

            container.settings.paste.openAccessibilitySettings()

            #expect(systemSettings.openCount == 1)
            #expect(keystrokes.requestCount == 1)
        }
    }

    @Test func returnPastesOnceTheSettingIsOn() async throws {
        try await withContainer { container in
            container.start()
            container.store.record(text: "copied", sourceApp: nil, at: ContainerFactory.date)
            container.historyWindow.show()
            let model = container.historyWindow.model
            let entry = try #require(model.selectedEntry)
            #expect(model.handleKey(.return, isCaretAtEnd: true) == .choose(entry, pastes: false))

            keystrokes.allowsWhenAsked = true
            container.settings.paste.setOn(true)

            #expect(keystrokes.requestCount == 1)
            #expect(model.handleKey(.return, isCaretAtEnd: true) == .choose(entry, pastes: true))
        }
    }

    /// Without permission the paste gives up at once, so the whole way can be followed without waiting: the entry is
    /// copied, nothing is posted or asked for, and the next window says why, once.
    @Test func choosingToPasteWithoutPermissionCopiesAndTheNextWindowSaysSo() async throws {
        try await withContainer { container in
            container.start()
            container.store.record(text: "copied", sourceApp: nil, at: ContainerFactory.date)
            let window = container.historyWindow
            window.show()
            let entry = try #require(window.model.selectedEntry)

            window.choose(entry, pastes: true)

            #expect(!window.isVisible)
            #expect(pasteboard.writtenTexts == ["copied"])
            #expect(keystrokes.postCount == 0)
            #expect(keystrokes.requestCount == 0)
            window.show()
            #expect(window.model.pasteHint == .noAccess)
            window.hide()
            window.show()
            #expect(window.model.pasteHint == nil)
        }
    }
}
