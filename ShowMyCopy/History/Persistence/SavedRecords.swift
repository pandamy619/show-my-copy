import Foundation

/// What `SavedRecords.sort` found in the saved records.
struct FoundRecords: Sendable {
    var entries: [ClipboardEntry] = []
    /// Damaged, not to be opened, or an image whose data or thumbnail is gone: deleted.
    var unreadable: [UUID] = []
    /// Passwords that are expired or no longer saved: deleted unopened.
    var unwanted: [UUID] = []
}

/// How `PersistentHistoryStore` sorts the records it loads at launch and finds the blobs no record uses.
enum SavedRecords {
    /// Sorts the saved records into entries to load and records to delete. Records with blobs while there is no
    /// blob store are in neither: they stay on disk.
    static func sort(
        _ records: [StoredEntryRecord],
        coder: StoredEntryCoder,
        savesPasswords: Bool,
        at now: Date,
        blobs: (any BlobStore)?
    ) -> FoundRecords {
        var found = FoundRecords()
        for record in records {
            // Decided before opening: opening asks for the key, which can show a Keychain prompt.
            if isUnwantedPassword(record, savesPasswords: savesPasswords, at: now) {
                found.unwanted.append(record.id)
                continue
            }
            var missing: Set<BlobID> = []
            if !record.blobIDs.isEmpty {
                guard let blobs else {
                    // Nowhere to read the data from now; a later launch with the blob store loads it.
                    continue
                }
                missing = Set(record.blobIDs.map { BlobID(uuid: $0) }.filter { !blobs.contains($0) })
            }
            switch coder.decode(record) {
            case .entry(let entry):
                // An image whose data is gone is deleted; files whose thumbnails are gone keep their icons.
                guard let content = entry.content.droppingBlobs(missing) else {
                    found.unreadable.append(record.id)
                    continue
                }
                found.entries.append(content == entry.content ? entry : entry.replacingContent(content))
            case .unreadable:
                found.unreadable.append(record.id)
            }
        }
        return found
    }

    /// Deletes the blobs that no record references.
    static func deleteOrphans(in blobs: any BlobStore, keeping referenced: Set<BlobID>) {
        do {
            let orphans = try blobs.allIDs().subtracting(referenced)
            guard !orphans.isEmpty else {
                return
            }
            AppLogger.history.info("Deleting \(orphans.count, privacy: .public) saved images no entry uses")
            try blobs.delete(Array(orphans))
        } catch {
            AppLogger.history.error("Could not delete saved images no entry uses; trying again at the next launch")
        }
    }

    /// Whether `record` is a saved password that is no longer wanted: expired at `now`, or saving passwords is off.
    private static func isUnwantedPassword(_ record: StoredEntryRecord, savesPasswords: Bool, at now: Date) -> Bool {
        guard record.isConcealed else {
            return false
        }
        guard savesPasswords else {
            return true
        }
        guard let expiresAt = record.expiresAt else {
            return false
        }
        return expiresAt <= now
    }
}
