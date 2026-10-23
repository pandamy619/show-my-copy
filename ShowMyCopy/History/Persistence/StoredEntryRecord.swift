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
struct StoredEntryRecord: Equatable, Sendable {
    /// Change it when a field changes meaning. Records with a newer version are left on disk and not loaded, so
    /// going back to an older app version does not destroy what a newer one saved.
    static let currentSchemaVersion = 1

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
}
