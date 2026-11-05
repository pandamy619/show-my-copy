import Foundation

/// What is read from the app bundle the user picks with Settings → Excluded apps → Choose an App…: its bundle
/// identifier and the name to show, nothing else. Where the bundle is is not part of it, so no path, URL or bookmark
/// can be kept by mistake.
struct ChosenApp: Equatable, Sendable {
    let bundleIdentifier: String?
    let name: String?

    /// The most of a bundle's `Contents/Info.plist` that is read. Real ones are a few kilobytes; a larger one comes
    /// from a bundle that is not an ordinary app and is not parsed.
    static let maximumInfoPlistBytes = 512 * 1024

    init(bundleIdentifier: String?, name: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    /// From the data of the bundle's Info.plist, read with at most `maximumInfoPlistBytes + 1` bytes, or nil when it
    /// could not be read. The name is the bundle's display name, else its name, else `fileName` (the bundle's name
    /// on disk without `.app`). Without a readable Info.plist there is no bundle identifier, and the app cannot be
    /// excluded.
    init(infoPlist data: Data?, fileName: String) {
        let info = data.flatMap(Self.dictionary)
        bundleIdentifier = info?["CFBundleIdentifier"] as? String
        let names = [info?["CFBundleDisplayName"], info?["CFBundleName"]].compactMap { $0 as? String }
        name = (names + [fileName]).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func dictionary(from data: Data) -> [String: Any]? {
        guard data.count <= maximumInfoPlistBytes else {
            AppLogger.app.error("The chosen app's Info.plist is too large")
            return nil
        }
        do {
            let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            if info == nil {
                AppLogger.app.error("The chosen app's Info.plist is not a dictionary")
            }
            return info
        } catch {
            AppLogger.app.error("Could not read the chosen app's Info.plist")
            return nil
        }
    }
}

/// What came of adding a chosen app, for the note under the buttons.
enum ChosenAppOutcome: Equatable, Sendable {
    case added(ExcludedApp)
    /// The app is in the list already; nothing changed.
    case alreadyExcluded(ExcludedApp)
    /// The bundle has no bundle identifier (or no Info.plist that could be read): the app could never be recognized.
    case noBundleIdentifier
    /// Show My Copy itself: its own copies are not what the list is for.
    case thisApp
}

/// Asks the user to pick an app. The real one is an open panel (`ApplicationOpenPanel`); it reads the chosen
/// bundle's identifier and name off the main actor and keeps nothing else.
@MainActor
protocol AppChoosing {
    /// Nil when the user cancels.
    func chooseApp() async -> ChosenApp?
}
