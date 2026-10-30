import Foundation
import Observation

/// Why choosing an entry to paste it only copied it. The history window says so once, the next time it opens.
enum PasteFallback: Equatable, Sendable {
    /// macOS does not let the app post key events: never allowed, or turned off since in System Settings.
    case noAccess
    /// The key events could not be made.
    case couldNotPost
}

/// Settings → General → Paste after choosing an entry: whether Return pastes the chosen entry into the app the user
/// was working in, or only copies it.
///
/// Off by default. Pasting needs the user to allow the app to post key events (`PasteAccessChecking`), and the app
/// asks for that only when the user turns this on. The setting is saved; the privilege lives in macOS, where the user
/// can take it back at any time, so it is read again every time Settings open or come to the front and before every
/// paste, and never saved by the app.
@MainActor
@Observable
final class PasteSettings {
    /// What macOS says about posting key events.
    enum Access: Equatable, Sendable {
        case granted
        case notGranted
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let accessChecker: any PasteAccessChecking
    /// A paste that fell back to copying and that the history window has not told about yet. Kept in memory: after
    /// a relaunch the user has not just tried to paste.
    @ObservationIgnored private var pendingFallback: PasteFallback?

    /// Whether Return pastes after copying. ⌥Return does the other.
    private(set) var isOn: Bool
    /// What macOS said last; nil until the first read.
    private(set) var access: Access?

    init(defaults: UserDefaults, accessChecker: any PasteAccessChecking) {
        self.defaults = defaults
        self.accessChecker = accessChecker
        isOn = defaults.object(forKey: SettingsKey.pasteAfterChoosing) as? Bool ?? false
    }

    /// Whether Settings say the app may not paste: the setting is on, and macOS does not let the app post key events.
    /// Then Return only copies.
    var needsAccess: Bool {
        isOn && access == .notGranted
    }

    /// Turns pasting after choosing on or off. Turning it on asks macOS for the privilege when the app lacks it;
    /// macOS shows its own alert while it still asks for this app. Turning it off leaves the privilege as it is: only
    /// the user can take it back, in System Settings, and Settings say so.
    func setOn(_ isOn: Bool) {
        guard isOn != self.isOn else {
            return
        }
        self.isOn = isOn
        defaults.set(isOn, forKey: SettingsKey.pasteAfterChoosing)
        if isOn && !accessChecker.isGranted() {
            accessChecker.request()
        }
        refresh()
    }

    /// Reads the privilege again: Settings opened or came to the front, for example when the user comes back from
    /// System Settings.
    func refresh() {
        update(granted: accessChecker.isGranted())
    }

    /// Asks macOS for the privilege again, for the button under the setting.
    func requestAccess() {
        update(granted: accessChecker.request())
    }

    /// Whether macOS lets the app post key events now. The paster asks before every paste; the answer also updates
    /// what Settings show.
    func checkAccess() -> Bool {
        let granted = accessChecker.isGranted()
        update(granted: granted)
        return granted
    }

    /// A paste only copied. The history window says why the next time it opens, unless it said so before and the
    /// app has not pasted since.
    func pasteFellBack(_ reason: PasteFallback) {
        guard !defaults.bool(forKey: SettingsKey.pasteDidShowFallbackHint) else {
            return
        }
        pendingFallback = reason
    }

    /// The fallback the history window opening now tells about, once. Nil when there is none.
    func takeFallbackHint() -> PasteFallback? {
        guard let pendingFallback else {
            return nil
        }
        self.pendingFallback = nil
        defaults.set(true, forKey: SettingsKey.pasteDidShowFallbackHint)
        return pendingFallback
    }

    /// While the app may paste, a later problem (the user takes the privilege back) gets its hint again.
    private func update(granted: Bool) {
        let access: Access = granted ? .granted : .notGranted
        if self.access != access {
            self.access = access
        }
        if granted {
            defaults.removeObject(forKey: SettingsKey.pasteDidShowFallbackHint)
        }
    }
}
