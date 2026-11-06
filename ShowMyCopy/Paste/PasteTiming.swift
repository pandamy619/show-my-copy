/// How long the paster waits after the history window closed before it sends ⌘V.
///
/// The history panel takes key focus from the app the user works in without activating this app. When it closes,
/// macOS hands key focus back to that app's window, and the app then has to make its window key again and focus the
/// field the user was in. Native apps such as Telegram do that at once. Chromium and Electron apps (Chrome, the
/// Claude app, VS Code, Slack) take longer: their web view handles ⌘V only while its window is key
/// (`-[RenderWidgetHostViewCocoa performKeyEquivalent:]` returns NO otherwise), and focusing the page goes from the
/// app's main thread to the page's process. A ⌘V that arrives before that pastes nothing.
///
/// So the paster first waits until the window server no longer shows the panel, checking every `pollInterval` for at
/// most `longestWaitForWindow`, and then waits `settleDelay` more for the app to make its window key and focus its
/// field. Altogether it waits at most `longestWait`.
struct PasteTiming: Equatable, Sendable {
    /// How often the paster checks whether the panel is gone.
    var pollInterval: Duration
    /// How long the paster checks at most. When the panel is still on screen then, the paste is given up.
    var longestWaitForWindow: Duration
    /// How long the app in front gets, after the panel is gone, to make its window key and focus its field.
    var settleDelay: Duration

    /// Short enough that the paste feels immediate, long enough for Chromium and Electron apps. The panel is usually
    /// gone after one or two checks, so a paste usually waits about 0.15 to 0.2 seconds.
    static let standard = PasteTiming(
        pollInterval: .milliseconds(10),
        longestWaitForWindow: .milliseconds(250),
        settleDelay: .milliseconds(150)
    )

    /// The longest the paster waits in all.
    var longestWait: Duration {
        longestWaitForWindow + settleDelay
    }

    /// Waits until `windowIsGone` says the history window is off screen, or `longestWaitForWindow` passed, then
    /// `settleDelay`. Counts the time by the waits it asks for, so a test's sleep that returns at once ends it too.
    /// A cancelled wait does not end it early: the caller's checks decide whether to paste.
    @MainActor
    func waitForFocus(
        windowIsGone: () -> Bool,
        sleep: @Sendable (Duration) async throws -> Void
    ) async {
        var waited = Duration.zero
        while !windowIsGone(), waited < longestWaitForWindow {
            try? await sleep(pollInterval)
            waited += pollInterval
        }
        try? await sleep(settleDelay)
    }
}
