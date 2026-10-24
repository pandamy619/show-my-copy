import Foundation

/// One history entry as it is written to disk. A plain value, so the mapping and the history logic are tested
/// without SwiftData; `SwiftDataHistoryPersistence` copies it field by field into its model.
///
/// What a record may hold is a security decision:
/// - `payload` is the content's data: UTF-8 for text. For a concealed entry it is sealed (encrypted) bytes.
/// - `contentHash` and `previewText` are nil for a concealed entry. A plain hash of a password could be checked
///   against a list of common passwords, and the preview is the password itself. Both are made again in memory
///   after the payload is opened.
/// - `byteSize` is 0 for a concealed entry, so the record does not tell how long the password is.
/// - An image record's payload holds blob IDs and metadata only; the image data and its thumbnail are files in the
///   blob store. A file record holds the thumbnails of copied photos and videos the same way, never the files.
///   `blobIDs` lists them in plain, so blobs are found without opening or understanding the payload.
struct StoredEntryRecord: Equatable, Sendable {
    /// The newest version this app reads. Change it when a field changes meaning. Records with a newer version are
    /// left on disk and not loaded, so going back to an older app version does not destroy what a newer one saved.
    ///
    /// 2: rich text, image and file records, and `blobIDs`.
    /// 3: file records with thumbnails of photos and videos (payload format 2, thumbnails in `blobIDs`).
    static let currentSchemaVersion = 3

    /// The version a record of `content` is written with: the oldest that can read it. Text records keep version
    /// 1, so an older app version still loads them after going back; it leaves the newer kinds alone. Files without
    /// thumbnails keep version 2 for the same reason. An older version leaves files with thumbnails on disk instead
    /// of deleting them as unreadable, and keeps their thumbnails, which `blobIDs` lists.
    static func schemaVersion(for content: ClipboardContent) -> Int {
        switch content {
        case .text:
            1
        case .richText, .image:
            2
        case .files:
            StoredPayload.formatVersion(for: content) == StoredPayload.filesWithThumbnailsFormatVersion ? 3 : 2
        }
    }

    var id: UUID
    /// `ClipboardContent.Kind.rawValue`. A kind this version does not know is left on disk and not loaded.
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
    var schemaVersion: Int
    /// The blobs the entry keeps in the blob store (an image's data and thumbnail, the thumbnails of copied photos
    /// and videos). Empty for other content.
    var blobIDs: [UUID] = []
}
