import Foundation

/// What became of a paste after an entry was copied. Every outcome but `.pasted` leaves the entry on the clipboard
/// only, as choosing it did before pasting existed.
enum PasteOutcome: Equatable, Sendable {
    case pasted
    /// macOS does not let the app post key events. The history window says so once.
    case noAccess
    /// The key events could not be made. The history window says so once.
    case couldNotPost
    /// Something else was copied after the entry: pasting now would paste that instead.
    case clipboardChanged
    /// The app in front changed while the history window closed, or it is this app (for example with Settings in
    /// front): ⌘V would land somewhere the user did not choose.
    case appChanged
    /// The history window was still on screen, or open again, when ⌘V was due: ⌘V would land in it.
    case historyWindowOpen
}

/// Pastes the entry the user just chose into the app they were working in. `EntryPaster` is the app's
/// implementation; the history window only hands over what it copied.
@MainActor
protocol EntryPasting: AnyObject {
    /// Called right after the chosen entry was put on the clipboard, at `changeCount`, and the history window was
    /// told to close. `historyWindowIsGone` says whether the window server no longer shows it. The returned task
    /// finishes once ⌘V was sent or the paste was given up.
    @discardableResult
    func paste(
        copiedAt changeCount: Int,
        historyWindowIsGone: @escaping @MainActor () -> Bool
    ) -> Task<PasteOutcome, Never>

    /// The fallback the history window opening now tells about, once (`PasteSettings.takeFallbackHint()`).
    func takeFallbackHint() -> PasteFallback?
}

/// Sends ⌘V to the app in front after the history window closed, only when that is sure to paste the chosen entry.
///
/// The history panel never activates the app (`HistoryPanel` is a non-activating panel), so the app the user was
/// working in stays the active app while the panel is open; the panel only takes key focus. Ordering the panel out
/// gives key focus back to that app's window, and that app takes a moment to make its window key and focus its field
/// again, Chromium and Electron apps longer than native ones. So the paster waits until the panel is gone and then a
/// little more (`PasteTiming`) before it sends ⌘V. Then it checks, in order:
///
/// 1. macOS lets the app post key events (checked first too, so a paste without the privilege does not wait),
/// 2. the clipboard still holds what the app wrote (its change count is the one the copy returned): something copied
///    in between would be pasted instead,
/// 3. the app in front is the one that was in front when the window closed, and not this app,
/// 4. the history window is not on screen: when it did not go in time, or the user opened it again, ⌘V would land in
///    its search field.
///
/// Passwords are pasted like anything else: they are on the clipboard already, marked as concealed, and the paster
/// never reads the clipboard's contents, only its change count. Nothing about the entry is logged.
@MainActor
final class EntryPaster: EntryPasting {
    private let pasteboard: any PasteboardReading
    private let keystrokes: any PasteKeystrokePosting
    private let settings: PasteSettings
    private let frontmostApp: @MainActor () -> SourceApp?
    /// This app's bundle identifier: ⌘V is never sent to this app.
    private let ownBundleIdentifier: String?
    private let sleep: @Sendable (Duration) async throws -> Void
    /// How long to wait and how to post, read for every paste (`PasteTuning.current()`).
    private let tuning: @MainActor () -> PasteTuning

    init(
        pasteboard: any PasteboardReading,
        keystrokes: any PasteKeystrokePosting,
        settings: PasteSettings,
        frontmostApp: @escaping @MainActor () -> SourceApp?,
        ownBundleIdentifier: String?,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        tuning: @escaping @MainActor () -> PasteTuning
    ) {
        self.pasteboard = pasteboard
        self.keystrokes = keystrokes
        self.settings = settings
        self.frontmostApp = frontmostApp
        self.ownBundleIdentifier = ownBundleIdentifier
        self.sleep = sleep
        self.tuning = tuning
    }

    @discardableResult
    func paste(
        copiedAt changeCount: Int,
        historyWindowIsGone: @escaping @MainActor () -> Bool
    ) -> Task<PasteOutcome, Never> {
        guard settings.checkAccess() else {
            return finished(.noAccess)
        }
        let target = frontmostApp()
        let tuning = tuning()
        return Task { @MainActor in
            await tuning.timing.waitForFocus(windowIsGone: historyWindowIsGone, sleep: sleep)
            return finish(
                post(copiedAt: changeCount, into: target, historyWindowIsGone: historyWindowIsGone, style: tuning.style)
            )
        }
    }

    func takeFallbackHint() -> PasteFallback? {
        settings.takeFallbackHint()
    }

    private func post(
        copiedAt changeCount: Int,
        into target: SourceApp?,
        historyWindowIsGone: () -> Bool,
        style: PastePostingStyle
    ) -> PasteOutcome {
        // The user can take the privilege back while the window closes; macOS would drop the events silently.
        guard settings.checkAccess() else {
            return .noAccess
        }
        guard pasteboard.changeCount == changeCount else {
            return .clipboardChanged
        }
        guard let target, !isThisApp(target), frontmostApp() == target else {
            return .appChanged
        }
        guard historyWindowIsGone() else {
            return .historyWindowOpen
        }
        return keystrokes.postPaste(style) ? .pasted : .couldNotPost
    }

    private func isThisApp(_ app: SourceApp) -> Bool {
        guard let ownBundleIdentifier, let bundleIdentifier = app.bundleIdentifier else {
            return false
        }
        return bundleIdentifier == ownBundleIdentifier
    }

    private func finished(_ outcome: PasteOutcome) -> Task<PasteOutcome, Never> {
        let outcome = finish(outcome)
        return Task { outcome }
    }

    /// Logs the outcome with a constant message and tells Settings about a fallback the user should hear about.
    private func finish(_ outcome: PasteOutcome) -> PasteOutcome {
        switch outcome {
        case .pasted:
            AppLogger.clipboard.info("Pasted the chosen entry into the app in front")
        case .noAccess:
            AppLogger.clipboard.info("Copied the chosen entry without pasting: not allowed to post key events")
            settings.pasteFellBack(.noAccess)
        case .couldNotPost:
            AppLogger.clipboard.error("Copied the chosen entry without pasting: could not make the key events")
            settings.pasteFellBack(.couldNotPost)
        case .clipboardChanged:
            AppLogger.clipboard.info("Did not paste: something else was copied after the chosen entry")
        case .appChanged:
            AppLogger.clipboard.info("Did not paste: the app in front changed or is this app")
        case .historyWindowOpen:
            AppLogger.clipboard.info("Did not paste: the history window was on screen")
        }
        return outcome
    }
}
