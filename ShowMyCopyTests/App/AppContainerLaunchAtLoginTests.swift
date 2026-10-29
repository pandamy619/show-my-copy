import Foundation
import Testing

@testable import ShowMyCopy

/// Opening at login as the container wires it: off unless the user turns it on, offered once in the first launch's
/// Settings.
@MainActor
struct AppContainerLaunchAtLoginTests {
    private let loginItem = FakeLoginItem()
    private let settingsWindow = SettingsWindowSpy()

    private func withContainer(_ body: (AppContainer) async throws -> Void) async throws {
        try await ContainerFactory.withDefaults { defaults in
            let services = ContainerFactory.services(settingsWindow: settingsWindow, loginItem: loginItem)
            let container = AppContainer(
                history: .unsaved(InMemoryHistoryStore()), services: services, defaults: defaults)
            defer { container.monitor.stop() }
            try await body(container)
        }
    }

    @Test func launchingNeverMakesTheAppALoginItem() async throws {
        try await withContainer { container in
            container.start()
            container.showSettingsOnFirstLaunch()
            await container.settings.launchAtLogin.settingsOpened()

            #expect(loginItem.registerCount == 0)
            #expect(loginItem.unregisterCount == 0)
            #expect(!container.settings.launchAtLogin.isOn)
        }
    }

    @Test func buildingTheContainerDoesNotAskTheSystem() async throws {
        try await withContainer { container in
            container.start()
            #expect(loginItem.statusReads == 0)
            #expect(container.settings.launchAtLogin.status == nil)
        }
    }

    @Test func theFirstLaunchsSettingsSuggestTurningItOn() async throws {
        try await withContainer { container in
            container.showSettingsOnFirstLaunch()

            #expect(settingsWindow.showCount == 1)
            #expect(container.settings.launchAtLogin.suggestsTurningOn)
        }
    }

    @Test func settingsOpenedLaterDoNotSuggestIt() async throws {
        try await withContainer { container in
            container.showSettings()

            #expect(settingsWindow.showCount == 1)
            #expect(!container.settings.launchAtLogin.suggestsTurningOn)
        }
    }

    @Test func theSettingsWindowGetsTheContainersLoginItemSettings() async throws {
        try await withContainer { container in
            let settings = try #require(settingsWindow.settings)
            #expect(settings.launchAtLogin === container.settings.launchAtLogin)

            await settings.launchAtLogin.settingsOpened()
            await settings.launchAtLogin.setOn(true)
            #expect(loginItem.registerCount == 1)
        }
    }
}
