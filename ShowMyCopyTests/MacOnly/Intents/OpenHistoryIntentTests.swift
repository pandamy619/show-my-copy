import AppIntents
import Testing

@testable import ShowMyCopy

/// The Control Center extension is built with the same intent, but only the app has the history. These settings are
/// what keeps the intent out of the extension and the app in the background.
struct OpenHistoryIntentTests {
    /// A widget extension runs in the background only, so a foreground mode leaves the app as the only process that
    /// can perform the intent. Dynamic starts the app without bringing it forward; the history panel never activates
    /// the app either.
    @available(macOS 26, *)
    @Test func runsOnlyInTheAppWithoutActivatingIt() {
        #expect(OpenHistoryIntent.supportedModes == .foreground(.dynamic))
    }

    /// The button is the only way in: the action is not offered in Shortcuts or Spotlight.
    @available(macOS 26, *)
    @Test func isNotOfferedInShortcuts() {
        #expect(!OpenHistoryIntent.isDiscoverable)
    }
}
