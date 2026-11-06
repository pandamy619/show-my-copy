import Testing

@testable import ShowMyCopy

/// The pages of the settings window's sidebar and which one Settings open on.
struct SettingsSectionTests {
    @Test func theSidebarListsThePagesInThisOrder() {
        #expect(SettingsSection.allCases == [.general, .history, .storage, .passwords, .excludedApps, .about])
    }

    @Test func eachPageHasItsOwnSymbol() {
        let symbols = SettingsSection.allCases.map(\.symbolName)
        #expect(
            symbols == [
                "gearshape", "clock.arrow.circlepath", "internaldrive", "key.fill", "hand.raised.fill", "info",
            ])
        #expect(Set(symbols).count == symbols.count)
    }

    @Test func eachPageHasItsTint() {
        let tints = SettingsSection.allCases.map(\.tint)
        #expect(tints == [.gray, .blue, .indigo, .orange, .red, .gray])
    }

    @Test func settingsOpenOnGeneral() {
        #expect(SettingsSection.initial == .general)
    }

    /// Paste after choosing an entry is in General, whatever kept the paste from happening.
    @Test func thePasteHintOpensGeneral() {
        #expect(SettingsSection.showing(PasteFallback.noAccess) == .general)
        #expect(SettingsSection.showing(PasteFallback.couldNotPost) == .general)
    }
}
