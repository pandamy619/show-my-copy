import Foundation

/// One history entry as it is written to disk. A plain value, so the mapping and the history logic are tested
/// without SwiftData; `SwiftDataHistoryPersistence` copies it field by field into its model.
///
/// What a record may hold is a security decision:
/// - `payload` is the content's data in the `StoredPayload` layout. For a concealed entry it is sealed (encrypted)
///   bytes.
/// - `contentHash` and `previewText` are nil for a concealed entry. A plain hash of a password could be checked
///   against a list of common passwords, and the preview is the password itself. Both are made again in memory
///   after the payload is opened.
/// - `byteSize` is 0 for a concealed entry, so the record does not tell how long the password is.
/// - An image record's payload holds blob IDs and metadata only; the image data and its thumbnail are files in the
///   blob store. A file record holds the thumbnails of copied photos and videos the same way, never the files.
///   `blobIDs` lists them in plain, so blobs are found without opening or understanding the payload.
struct StoredEntryRecord: Equatable, Sendable {
    var id: UUID
    /// `ClipboardContent.Kind.rawValue`. A record of another kind is unreadable.
    var kind: String
    var payload: Data
    /// `ContentHash.description` (lower-case hex). Nil for a concealed entry.
    var contentHash: String?
    var byteSize: Int
    /// Nil for a concealed entry.
    var previewText: String?
    var date: Date
    var sourceAppBundleIdentifier: String?
    var sourceAppName: String?
    var isConcealed: Bool
    var expiresAt: Date?
    var isPinned: Bool
    /// The blobs the entry keeps in the blob store (an image's data and thumbnail, the thumbnails of copied photos
    /// and videos). Empty for other content.
    var blobIDs: [UUID] = []
}
