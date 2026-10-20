import AppKit

extension SourceApp {
    /// The active app is the best available guess for where a copy came from.
    @MainActor
    static func frontmost() -> SourceApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return SourceApp(bundleIdentifier: app.bundleIdentifier, name: app.localizedName)
    }
}
