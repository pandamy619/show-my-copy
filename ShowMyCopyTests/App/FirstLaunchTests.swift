import Foundation
import Testing

@testable import ShowMyCopy

struct FirstLaunchTests {
    /// Runs `body` with an empty UserDefaults suite that is removed afterwards.
    @Test func showsSettingsOnTheFirstLaunch() throws {
        try TestDefaults.with { defaults in
            #expect(FirstLaunch(defaults: defaults).shouldShowSettings)
        }
    }

    @Test func showsSettingsOnlyOnce() throws {
        try TestDefaults.with { defaults in
            let firstLaunch = FirstLaunch(defaults: defaults)
            firstLaunch.settingsWereShown()
            #expect(!firstLaunch.shouldShowSettings)
            // The next launch reads the same defaults.
            #expect(!FirstLaunch(defaults: defaults).shouldShowSettings)
        }
    }

    @Test func showsSettingsAgainWhenTheyWereNotShown() throws {
        try TestDefaults.with { defaults in
            _ = FirstLaunch(defaults: defaults).shouldShowSettings
            #expect(FirstLaunch(defaults: defaults).shouldShowSettings)
        }
    }
}
