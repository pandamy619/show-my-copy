import Testing

@testable import ShowMyCopy

/// Which page the settings window shows: General when it opens, the page a caller asks for, and General again once
/// the window is closed.
@MainActor
struct SettingsNavigationTests {
    @Test func startsOnGeneral() {
        let navigation = SettingsNavigation()

        #expect(navigation.selection == .general)
        #expect(navigation.shown == .general)
    }

    @Test func showsThePageACallerAsksFor() {
        let navigation = SettingsNavigation()

        navigation.show(.storage)

        #expect(navigation.shown == .storage)
    }

    @Test func showingWithoutAPageKeepsTheOneTheUserPicked() {
        let navigation = SettingsNavigation()
        navigation.selection = .excludedApps

        navigation.show(nil)

        #expect(navigation.shown == .excludedApps)
    }

    @Test func aPageAskedForReplacesTheOneTheUserPicked() {
        let navigation = SettingsNavigation()
        navigation.selection = .about

        navigation.show(.general)

        #expect(navigation.shown == .general)
    }

    @Test func closingTheWindowGoesBackToGeneral() {
        let navigation = SettingsNavigation()
        navigation.show(.passwords)

        navigation.windowClosed()

        #expect(navigation.selection == .general)
    }

    /// The sidebar can lose its selection, such as with a ⌘-click on the selected row; the page stays General then.
    @Test func showsGeneralWithNothingSelected() {
        let navigation = SettingsNavigation()
        navigation.selection = nil

        #expect(navigation.shown == .general)
    }
}
