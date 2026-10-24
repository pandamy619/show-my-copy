import Foundation

/// A copied file or folder: where it was and what it was called, never its contents.
///
/// The app is sandboxed and asks for no file access, so it keeps only what the pasteboard says: the file URL. It
/// cannot keep a security-scoped bookmark (that needs the user to pick the file in an open panel and a bookmark
/// entitlement), so it cannot follow a file that is moved. Copying the entry back puts the same file URL on the
/// pasteboard; the app that pastes it, such as Finder, opens the file with its own rights.
///
/// A photo or video may have a thumbnail, made once when it was copied (see `FileThumbnailIngestor`): after a
/// relaunch the sandbox no longer lets the app read the file, so the thumbnail cannot be made later.
struct FileReference: Equatable, Sendable {
    /// A file URL.
    let url: URL
    /// The name shown for the file: its last path component when it was copied.
    let name: String
    /// The size in bytes when it was copied, or nil for a folder or when the sandbox did not let the app read it.
    let byteSize: Int?
    /// A small picture of a photo or video, kept in the blob store, or nil for other files and when none could be
    /// made. Not part of the file's identity: the path is.
    let thumbnail: FileThumbnail?

    init(url: URL, name: String? = nil, byteSize: Int? = nil, thumbnail: FileThumbnail? = nil) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.byteSize = byteSize
        self.thumbnail = thumbnail
    }

    /// The same file with another thumbnail, or none.
    func withThumbnail(_ thumbnail: FileThumbnail?) -> FileReference {
        FileReference(url: url, name: name, byteSize: byteSize, thumbnail: thumbnail)
    }

    /// The path, which identifies the file in the history: copying the same file again finds the entry.
    var path: String {
        url.path(percentEncoded: false)
    }
}

/// The thumbnail of a copied photo or video file: PNG data in the blob store, like an image's thumbnail. The file
/// itself is never copied or kept.
struct FileThumbnail: Equatable, Sendable {
    /// What the file is. The raw values are saved with the history, so never change them.
    enum Kind: UInt8, CaseIterable, Sendable {
        /// A photo or other image file.
        case image = 1
        /// A video: the thumbnail is a frame of it, and rows show a play badge on it.
        case movie = 2
    }

    let kind: Kind
    let reference: ThumbnailReference

    var blobID: BlobID {
        reference.blobID
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
