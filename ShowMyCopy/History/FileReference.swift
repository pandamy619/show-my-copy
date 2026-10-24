import Foundation

/// A copied file or folder: where it was and what it was called, never its contents.
///
/// The app is sandboxed and asks for no file access, so it keeps only what the pasteboard says: the file URL. It
/// cannot keep a security-scoped bookmark (that needs the user to pick the file in an open panel and a bookmark
/// entitlement), so it cannot follow a file that is moved. Copying the entry back puts the same file URL on the
/// pasteboard; the app that pastes it, such as Finder, opens the file with its own rights.
struct FileReference: Equatable, Sendable {
    /// A file URL.
    let url: URL
    /// The name shown for the file: its last path component when it was copied.
    let name: String
    /// The size in bytes when it was copied, or nil for a folder or when the sandbox did not let the app read it.
    let byteSize: Int?

    init(url: URL, name: String? = nil, byteSize: Int? = nil) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.byteSize = byteSize
    }

    /// The path, which identifies the file in the history: copying the same file again finds the entry.
    var path: String {
        url.path(percentEncoded: false)
    }
}

/// Whether a copied file can still be found.
enum FileAvailability: Equatable, Sendable {
    /// The file is where it was copied from.
    case available
    /// The app cannot see the file there. It may have been moved or deleted, or the sandbox may hide it: a
    /// sandboxed app cannot tell a missing file from one it is not allowed to look at. Show it as "may be
    /// unavailable", never as deleted.
    case mayBeUnavailable
}

/// Checks whether copied files can still be found, for marking entries whose file may be gone.
protocol FileAvailabilityChecking: Sendable {
    func availability(of file: FileReference) -> FileAvailability
}

/// Asks the file system. In the sandbox `FileManager.fileExists` answers false for files outside the container
/// that the app has no access to, so `mayBeUnavailable` is all a false answer means. Touches the disk, so check
/// when an entry is shown, not for the whole history at once.
struct FileSystemAvailabilityChecker: FileAvailabilityChecking {
    func availability(of file: FileReference) -> FileAvailability {
        FileManager.default.fileExists(atPath: file.path) ? .available : .mayBeUnavailable
    }
}
