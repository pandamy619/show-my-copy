import Foundation
import Testing

@testable import ShowMyCopy

struct FirstLaunchTests {
    /// Runs `body` with an empty UserDefaults suite that is removed afterwards.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "ShowMyCopyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @Test func showsSettingsOnTheFirstLaunch() throws {
        try withDefaults { defaults in
            #expect(FirstLaunch(defaults: defaults).shouldShowSettings)
        }
    }

    @Test func showsSettingsOnlyOnce() throws {
        try withDefaults { defaults in
            let firstLaunch = FirstLaunch(defaults: defaults)
            firstLaunch.settingsWereShown()
            #expect(!firstLaunch.shouldShowSettings)
            // The next launch reads the same defaults.
            #expect(!FirstLaunch(defaults: defaults).shouldShowSettings)
        }
    }

    @Test func showsSettingsAgainWhenTheyWereNotShown() throws {
        try withDefaults { defaults in
            _ = FirstLaunch(defaults: defaults).shouldShowSettings
            #expect(FirstLaunch(defaults: defaults).shouldShowSettings)
        }
    }
}
