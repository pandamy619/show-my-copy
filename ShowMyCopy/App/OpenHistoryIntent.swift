import AppIntents

/// Opens the clipboard history: the action of the Control Center button (`HistoryControl` in the extension).
///
/// This file is built into the app and into the Control Center extension (a membership exception in the project).
/// The extension needs the type to make the button; only the app can perform it, because only the app has the
/// history. The system picks which process performs an intent that both declare. A widget extension runs in the
/// background only, so a foreground mode leaves the app: `dynamic` launches it if needed without bringing it forward
/// (the app has no Dock icon and its history panel never activates it). Never add `.background`: the extension could
/// then be chosen, and it has no history to show.
@available(macOS 26, *)
struct OpenHistoryIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Clipboard History" }

    /// The button is the only way in. Offering the action in Shortcuts and Spotlight would be a feature of its own.
    static let isDiscoverable = false

    // A constant, as in Apple's documentation of `supportedModes`.
    static let supportedModes: IntentModes = .foreground(.dynamic)

    /// Registered by the app at launch (`AppDelegate`). The extension registers nothing, so performing the intent
    /// there fails instead of doing nothing.
    @Dependency private var requests: HistoryRequests

    @MainActor
    func perform() async throws -> some IntentResult {
        requests.showHistory()
        return .result()
    }
}
