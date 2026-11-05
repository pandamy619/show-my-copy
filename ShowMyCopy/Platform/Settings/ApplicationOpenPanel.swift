import AppKit
import UniformTypeIdentifiers

/// Settings → Excluded apps → Choose an App…: an open panel for one app, starting in /Applications.
///
/// The panel runs outside the app (macOS's Powerbox), and the sandbox lets the app read only the bundle the user
/// picks, because the app has `com.apple.security.files.user-selected.read-only` (SECURITY.md). The app reads that
/// bundle's Info.plist once, off the main actor, for its bundle identifier and name, and gives the access back. It
/// keeps no URL, path or bookmark: `ChosenApp` has no field for one.
@MainActor
struct ApplicationOpenPanel: AppChoosing {
    func chooseApp() async -> ChosenApp? {
        let panel = NSOpenPanel()
        // Apps only, one at a time. An app bundle is a package: it is picked as a whole, and no other folder can be.
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.message = String(localized: "Choose an app whose copies are never recorded.")
        panel.prompt = String(localized: "Exclude")
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response)
            }
        }
        guard response == .OK, let bundle = panel.url else {
            return nil
        }
        let chosen = await Task.detached(priority: .userInitiated) {
            Self.read(bundleAt: bundle)
        }.value
        // Access to a URL from an open panel lasts until the app quits unless it is given back; nothing else is read.
        bundle.stopAccessingSecurityScopedResource()
        return chosen
    }

    /// The bundle identifier and name of the app at `bundle`, from at most `ChosenApp.maximumInfoPlistBytes` (plus
    /// one, to tell a larger file) of its `Contents/Info.plist`. Reads the disk, so never on the main actor.
    nonisolated static func read(bundleAt bundle: URL) -> ChosenApp {
        let fileName = bundle.deletingPathExtension().lastPathComponent
        let infoPlist = bundle.appending(components: "Contents", "Info.plist", directoryHint: .notDirectory)
        let data: Data?
        do {
            let handle = try FileHandle(forReadingFrom: infoPlist)
            defer {
                do {
                    try handle.close()
                } catch {
                    AppLogger.app.error("Could not close the chosen app's Info.plist")
                }
            }
            data = try handle.read(upToCount: ChosenApp.maximumInfoPlistBytes + 1)
        } catch {
            AppLogger.app.error("Could not open the chosen app's Info.plist")
            data = nil
        }
        return ChosenApp(infoPlist: data, fileName: fileName)
    }
}
