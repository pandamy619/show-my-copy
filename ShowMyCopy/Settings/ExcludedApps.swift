import Foundation
import Observation

/// An app the user excluded: nothing copied while it is in front is read or recorded. Only its bundle identifier
/// and the name to show are kept, no path or bookmark, so the app may move or be updated and stays excluded.
struct ExcludedApp: Equatable, Hashable, Sendable, Identifiable {
    let bundleIdentifier: String
    /// Sanitized like any text the app shows that another app supplied.
    let name: String

    /// Bundle identifiers are compared without regard to letter case, as for password managers.
    var id: String {
        bundleIdentifier.lowercased()
    }

    /// Nil without a bundle identifier: such an app could never be recognized again. Without a name the bundle
    /// identifier is shown.
    init?(bundleIdentifier: String?, name: String?) {
        guard let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleIdentifier.isEmpty
        else {
            return nil
        }
        self.bundleIdentifier = bundleIdentifier
        let shownName = name.map(Self.oneLine) ?? ""
        self.name = shownName.isEmpty ? Self.oneLine(bundleIdentifier) : shownName
    }

    init?(_ app: SourceApp) {
        self.init(bundleIdentifier: app.bundleIdentifier, name: app.name)
    }

    /// The name comes from the app's bundle: without control characters or direction overrides, on one line.
    private static func oneLine(_ text: String) -> String {
        EntryPreview.text(text).split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// The apps open now that the user can switch to, for adding one to the excluded apps quickly. The real one asks
/// `NSWorkspace`; it leaves out this app and apps without a window in the Dock (agents, background helpers).
@MainActor
protocol RunningAppsListing {
    func runningApps() -> [SourceApp]
}

/// The apps the user excluded, kept in UserDefaults: it is a setting, not clipboard data. The clipboard monitor asks
/// `excludes(bundleIdentifier:)` before it reads anything from the pasteboard (`CopySource`).
///
/// Known password managers are a separate, built-in list (`PasswordManager`) and are not shown here.
@MainActor
@Observable
final class ExcludedApps {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let running: any RunningAppsListing

    /// Sorted by name.
    private(set) var apps: [ExcludedApp] {
        didSet {
            identifiers = Set(apps.map(\.id))
        }
    }

    /// The lower-cased bundle identifiers of `apps`, so the check on every copy does not walk the list.
    @ObservationIgnored private var identifiers: Set<String>

    init(defaults: UserDefaults, running: any RunningAppsListing) {
        self.defaults = defaults
        self.running = running
        let apps = Self.stored(in: defaults)
        self.apps = apps
        identifiers = Set(apps.map(\.id))
    }

    /// Whether copies made while the app with `bundleIdentifier` is in front are left alone. False for an unknown
    /// app.
    func excludes(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }
        return identifiers.contains(bundleIdentifier.lowercased())
    }

    /// Adds `app` unless it is excluded already, and saves the list.
    func add(_ app: ExcludedApp) {
        guard !identifiers.contains(app.id) else {
            return
        }
        apps = Self.sorted(apps + [app])
        save()
    }

    /// Removes `app` and saves the list. Copies made in it from now on are recorded again; nothing it copied while it
    /// was excluded was read, so there is nothing to bring back.
    func remove(_ app: ExcludedApp) {
        guard identifiers.contains(app.id) else {
            return
        }
        apps.removeAll { $0.id == app.id }
        save()
    }

    /// The open apps that can be added: each once, sorted by name, without those excluded already.
    func addableApps() -> [ExcludedApp] {
        var seen = identifiers
        let addable = running.runningApps().compactMap(ExcludedApp.init).filter { seen.insert($0.id).inserted }
        return Self.sorted(addable)
    }

    // MARK: - Saved list

    /// One dictionary per app, with these keys. Plain property-list values, so nothing has to be encoded.
    private enum StoredKey {
        static let bundleIdentifier = "bundleIdentifier"
        static let name = "name"
    }

    private func save() {
        let stored = apps.map { [StoredKey.bundleIdentifier: $0.bundleIdentifier, StoredKey.name: $0.name] }
        defaults.set(stored, forKey: SettingsKey.excludedApps)
    }

    /// The saved list. Entries that are not a dictionary with a bundle identifier, and repeated ones, are left out;
    /// the next change saves the list without them.
    private static func stored(in defaults: UserDefaults) -> [ExcludedApp] {
        let entries = defaults.array(forKey: SettingsKey.excludedApps) ?? []
        var seen: Set<String> = []
        let apps = entries.compactMap { entry -> ExcludedApp? in
            guard let entry = entry as? [String: Any] else {
                return nil
            }
            return ExcludedApp(
                bundleIdentifier: entry[StoredKey.bundleIdentifier] as? String, name: entry[StoredKey.name] as? String)
        }
        return sorted(apps.filter { seen.insert($0.id).inserted })
    }

    private static func sorted(_ apps: [ExcludedApp]) -> [ExcludedApp] {
        apps.sorted { lhs, rhs in
            switch lhs.name.localizedCaseInsensitiveCompare(rhs.name) {
            case .orderedAscending:
                true
            case .orderedDescending:
                false
            case .orderedSame:
                lhs.id < rhs.id
            }
        }
    }
}
