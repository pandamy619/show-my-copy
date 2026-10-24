import Foundation
import SwiftData

/// One saved history entry, as SwiftData keeps it. A copy of `StoredEntryRecord` field by field: what is sealed,
/// hashed or left out is decided by `StoredEntryCoder`, so this model holds no rules and needs no tests of its own
/// beyond the round trip.
///
/// A new field must be optional or have a default value, so SwiftData can migrate existing stores on its own.
@Model
final class StoredEntry {
    #Unique<StoredEntry>([\.id])
    #Index<StoredEntry>([\.date])

    var id: UUID
    var kind: String
    var payload: Data
    var contentHash: String?
    var byteSize: Int
    var previewText: String?
    var date: Date
    var sourceAppBundleIdentifier: String?
    var sourceAppName: String?
    var isConcealed: Bool
    var expiresAt: Date?
    var isPinned: Bool
    var schemaVersion: Int
    /// `StoredEntryRecord.blobIDs` as UUID strings separated by spaces, or nil when there are none. Added in
    /// schema version 2; optional, so stores from version 1 open with a lightweight migration and read as nil.
    var blobIDs: String?

    init(record: StoredEntryRecord) {
        id = record.id
        kind = record.kind
        payload = record.payload
        contentHash = record.contentHash
        byteSize = record.byteSize
        previewText = record.previewText
        date = record.date
        sourceAppBundleIdentifier = record.sourceAppBundleIdentifier
        sourceAppName = record.sourceAppName
        isConcealed = record.isConcealed
        expiresAt = record.expiresAt
        isPinned = record.isPinned
        schemaVersion = record.schemaVersion
        blobIDs = Self.joined(record.blobIDs)
    }

    /// Takes every field from `record` except the ID, which never changes.
    func update(from record: StoredEntryRecord) {
        kind = record.kind
        payload = record.payload
        contentHash = record.contentHash
        byteSize = record.byteSize
        previewText = record.previewText
        date = record.date
        sourceAppBundleIdentifier = record.sourceAppBundleIdentifier
        sourceAppName = record.sourceAppName
        isConcealed = record.isConcealed
        expiresAt = record.expiresAt
        isPinned = record.isPinned
        schemaVersion = record.schemaVersion
        blobIDs = Self.joined(record.blobIDs)
    }

    var record: StoredEntryRecord {
        StoredEntryRecord(
            id: id,
            kind: kind,
            payload: payload,
            contentHash: contentHash,
            byteSize: byteSize,
            previewText: previewText,
            date: date,
            sourceAppBundleIdentifier: sourceAppBundleIdentifier,
            sourceAppName: sourceAppName,
            isConcealed: isConcealed,
            expiresAt: expiresAt,
            isPinned: isPinned,
            schemaVersion: schemaVersion,
            blobIDs: Self.split(blobIDs)
        )
    }

    private static func joined(_ ids: [UUID]) -> String? {
        ids.isEmpty ? nil : ids.map(\.uuidString).joined(separator: " ")
    }

    /// Text that is not a UUID is dropped: a blob nobody references is deleted by the sweep at launch.
    private static func split(_ text: String?) -> [UUID] {
        (text ?? "").split(separator: " ").compactMap { UUID(uuidString: String($0)) }
    }
}
