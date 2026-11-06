import Foundation
import Testing

@testable import ShowMyCopy

/// What the container asks of the settings window: which page it opens on, and copying without recording.
@MainActor
struct AppContainerSettingsWindowTests {
    private let pasteboard = FakePasteboard()
    private let store = InMemoryHistoryStore(now: { ContainerFactory.date })
    private let settingsWindow = SettingsWindowSpy()

    private func withContainer(_ body: (AppContainer) async throws -> Void) async throws {
        try await ContainerFactory.withDefaults { defaults in
            let services = ContainerFactory.services(pasteboard: pasteboard, settingsWindow: settingsWindow)
            let container = AppContainer(history: .unsaved(store), services: services, defaults: defaults)
            defer { container.monitor.stop() }
            try await body(container)
        }
    }

    /// The login suggestion is in General, so the first launch's Settings open there.
    @Test func theFirstLaunchOpensGeneral() async throws {
        try await withContainer { container in
            container.showSettingsOnFirstLaunch()

            #expect(settingsWindow.shownSections == [.general])
        }
    }

    /// Opening the app again brings Settings to the front on the page they show, General when they were closed.
    @Test func openingTheAppAgainKeepsThePage() async throws {
        try await withContainer { container in
            container.showSettings()

            #expect(settingsWindow.shownSections == [nil])
        }
    }

    /// Like a folder copied from the history window's preview, the address copied from Settings → About goes on the
    /// clipboard without becoming an entry.
    @Test func textCopiedInSettingsIsNotRecorded() async throws {
        try await withContainer { container in
            pasteboard.copy("older")
            container.monitor.poll()
            let copyText = try #require(settingsWindow.copyText)

            copyText("https://github.com/pandamy619/show-my-copy")
            container.monitor.poll()

            #expect(pasteboard.writtenTexts == ["https://github.com/pandamy619/show-my-copy"])
            #expect(store.entries.map(\.text) == ["older"])
        }
    }
}
