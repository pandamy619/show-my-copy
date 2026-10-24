import Foundation
import SwiftData

/// One saved history entry, as SwiftData keeps it. A copy of `StoredEntryRecord` field by field: what is sealed,
/// hashed or left out is decided by `StoredEntryCoder`, so this model holds no rules and needs no tests of its own
/// beyond the round trip.
///
/// There is one layout, without versions: until the first release, a change to it replaces the store (see
/// `LegacyHistoryFiles`). From the first release on, this becomes a versioned schema with a migration plan.
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
    /// `StoredEntryRecord.blobIDs` as UUID strings separated by spaces, or nil when there are none.
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
