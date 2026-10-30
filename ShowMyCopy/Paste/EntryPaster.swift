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
}

/// Pastes the entry the user just chose into the app they were working in. `EntryPaster` is the app's
/// implementation; the history window only hands over what it copied.
@MainActor
protocol EntryPasting: AnyObject {
    /// Called right after the chosen entry was put on the clipboard, at `changeCount`, and the history window
    /// closed. The returned task finishes once ⌘V was sent or the paste was given up.
    @discardableResult
    func paste(copiedAt changeCount: Int) -> Task<PasteOutcome, Never>

    /// The fallback the history window opening now tells about, once (`PasteSettings.takeFallbackHint()`).
    func takeFallbackHint() -> PasteFallback?
}

/// Sends ⌘V to the app in front after the history window closed, only when that is sure to paste the chosen entry.
///
/// The history panel never activates the app (`HistoryPanel` is a non-activating panel), so the app the user was
/// working in stays the active app while the panel is open; the panel only takes key focus. Ordering the panel out
/// gives key focus back to that app's window, and the window server takes a moment to route key events there again.
/// So the paster waits `focusDelay` before it sends ⌘V. Then it checks, in order:
///
/// 1. macOS lets the app post key events (checked first too, so a paste without the privilege does not wait),
/// 2. the clipboard still holds what the app wrote (its change count is the one the copy returned): something copied
///    in between would be pasted instead,
/// 3. the app in front is the one that was in front when the window closed, and not this app.
///
/// Passwords are pasted like anything else: they are on the clipboard already, marked as concealed, and the paster
/// never reads the clipboard's contents, only its change count. Nothing about the entry is logged.
@MainActor
final class EntryPaster: EntryPasting {
    /// How long the window server gets to give key focus back to the app in front before ⌘V is sent. Long enough
    /// for the panel to be ordered out, short enough that the paste feels immediate.
    nonisolated static let focusDelay: Duration = .milliseconds(100)

    private let pasteboard: any PasteboardReading
    private let keystrokes: any PasteKeystrokePosting
    private let settings: PasteSettings
    private let frontmostApp: @MainActor () -> SourceApp?
    /// This app's bundle identifier: ⌘V is never sent to this app.
    private let ownBundleIdentifier: String?
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        pasteboard: any PasteboardReading,
        keystrokes: any PasteKeystrokePosting,
        settings: PasteSettings,
        frontmostApp: @escaping @MainActor () -> SourceApp?,
        ownBundleIdentifier: String?,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.pasteboard = pasteboard
        self.keystrokes = keystrokes
        self.settings = settings
        self.frontmostApp = frontmostApp
        self.ownBundleIdentifier = ownBundleIdentifier
        self.sleep = sleep
    }

    @discardableResult
    func paste(copiedAt changeCount: Int) -> Task<PasteOutcome, Never> {
        guard settings.checkAccess() else {
            return finished(.noAccess)
        }
        let target = frontmostApp()
        return Task { @MainActor in
            do {
                try await sleep(Self.focusDelay)
            } catch {
                // Only a cancelled sleep throws. Paste anyway: the checks below still hold.
            }
            return finish(post(copiedAt: changeCount, into: target))
        }
    }

    func takeFallbackHint() -> PasteFallback? {
        settings.takeFallbackHint()
    }

    private func post(copiedAt changeCount: Int, into target: SourceApp?) -> PasteOutcome {
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
        return keystrokes.postPaste() ? .pasted : .couldNotPost
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
        }
        return outcome
    }
}
