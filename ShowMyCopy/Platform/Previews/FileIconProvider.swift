import AppKit

/// Icons for copied files in the history window.
protocol FileIconProviding: Sendable {
    /// The icon for the file at `path`. A generic document icon when the file cannot be found or the sandbox hides it.
    @MainActor func icon(forPath path: String) -> NSImage
}

/// Asks the workspace, which caches icons and reads only the file's type and custom icon, never its contents. Called
/// for the rows on screen and the open preview only.
struct WorkspaceFileIconProvider: FileIconProviding {
    @MainActor func icon(forPath path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }
}
