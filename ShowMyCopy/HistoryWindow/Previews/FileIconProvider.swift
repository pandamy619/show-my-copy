import AppKit
import UniformTypeIdentifiers

/// Icons for copied files in the history window. Asks the workspace, which caches icons and reads only the file's
/// type and custom icon, never its contents. Called for the rows on screen and the open preview only, on the main
/// actor, so it looks at the file itself only on the startup disk (`CopiedPaths`), and not when it is a symbolic
/// link: the workspace would follow it, and it can point anywhere, such as under `/net`, where looking it up makes
/// `automountd` contact a host. Elsewhere (a network volume, an automounted path, another disk that may have to spin
/// up, a cloud folder whose file may be a placeholder) the icon comes from the file name's extension alone and the
/// path is not touched.
struct WorkspaceFileIconProvider: Sendable {
    let paths: CopiedPaths

    init(paths: CopiedPaths = CopiedPaths()) {
        self.paths = paths
    }

    /// The icon for the file at `path`. A generic document icon when the file cannot be found or the sandbox hides it.
    @MainActor func icon(forPath path: String) -> NSImage {
        let url = URL(filePath: path)
        guard paths.access(for: url) == .startupDisk, !Self.isSymbolicLink(url) else {
            let type = UTType(filenameExtension: url.pathExtension) ?? .item
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(forFile: path)
    }

    /// Whether the path itself is a symbolic link, read without following it (`lstat`). A path that cannot be looked
    /// at counts as one: its icon then comes from its name alone.
    private static func isSymbolicLink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
            return true
        }
        return values.isSymbolicLink ?? true
    }
}
