import AppKit

/// The apps open now that have a Dock icon, as `NSWorkspace` lists them, without this app. Agents and background
/// helpers are left out: they are not what the user copies in. The workspace keeps this list in memory and updates it
/// as apps launch and quit, so reading it on the main actor touches no disk.
@MainActor
struct WorkspaceRunningApps: RunningAppsListing {
    func runningApps() -> [SourceApp] {
        let ownProcess = NSRunningApplication.current.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownProcess && !$0.isTerminated }
            .map { SourceApp(bundleIdentifier: $0.bundleIdentifier, name: $0.localizedName) }
    }
}
