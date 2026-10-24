import Foundation

/// What `SavedRecords.sort` found in the saved records.
struct FoundRecords: Sendable {
    var entries: [ClipboardEntry] = []
    /// Damaged, not to be opened, or an image whose data or thumbnail is gone: deleted.
    var unreadable: [UUID] = []
    /// Passwords that are expired or no longer saved: deleted unopened.
    var unwanted: [UUID] = []
    /// Passwords whose key cannot be used now: kept on disk unopened, and opened once it can.
    var unopened: [StoredEntryRecord] = []
}

/// The saved history found at launch, read and sorted: what `PersistentHistoryStore` starts from.
///
/// Loading is split so that what grows with the history runs off the main actor. `read(from:openError:leftovers:)`
/// only fetches the records, on the main actor, where the SwiftData context lives. `sorted(_:coder:savesPasswords:at:
/// blobs:)` then decodes every record (making its content, hash, preview and search key), checks that the blobs of
/// image and file records exist and lists the blob folder for the sweep; the app runs it in the background
/// (`sortedInBackground`). The store then only builds the list in memory and deletes what loading found unwanted.
struct LoadedHistory: Sendable {
    /// The records as read, before they are sorted.
    struct Read: Sendable {
        var records: [StoredEntryRecord]
        /// Why the records could not be read, or nil. Then the store starts empty and touches nothing on disk.
        var loadError: HistoryPersistenceError?
        /// Whether blobs no record references may be deleted: only when the store opened and was read and no other
        /// copy of a history is kept. After a failed open or load the records are unknown, and a damaged copy may
        /// reference any image, so their images may still be wanted.
        var sweepsBlobs: Bool
    }

    var loadError: HistoryPersistenceError?
    /// The entries newest first, and the records to delete or keep unopened.
    var found: FoundRecords
    /// The blobs each saved record references, by record ID.
    var blobsByRecord: [UUID: [BlobID]]
    /// Every blob stored when the history was loaded, for the sweep of those no record uses, or nil when there is no
    /// sweep.
    var storedBlobs: Set<BlobID>?

    /// Fetches the saved records. Only this step runs on the main actor.
    @MainActor
    static func read(
        from persistence: any HistoryPersistence,
        openError: HistoryPersistenceError?,
        leftovers: (any HistoryLeftovers)?
    ) -> Read {
        do {
            let records = try persistence.loadAll()
            return Read(
                records: records, loadError: nil, sweepsBlobs: openError == nil && leftovers?.hasFiles() != true)
        } catch {
            AppLogger.history.error("Could not read the saved history; starting with an empty one")
            return Read(records: [], loadError: error, sweepsBlobs: false)
        }
    }

    /// Sorts what `read` fetched. Decodes every record and reads blob metadata, so the app calls it off the main
    /// actor, through `sortedInBackground`.
    static func sorted(
        _ read: Read,
        coder: StoredEntryCoder,
        savesPasswords: Bool,
        at now: Date,
        blobs: (any BlobStore)?
    ) -> LoadedHistory {
        var found = SavedRecords.sort(
            read.records, coder: coder, savesPasswords: savesPasswords, at: now, blobs: blobs)
        // Each copy moves its entry to the top with the copy's date, so newest first is by date.
        found.entries.sort { $0.date > $1.date }
        let blobsByRecord = Dictionary(
            read.records.map { ($0.id, $0.blobIDs.map { BlobID(uuid: $0) }) }, uniquingKeysWith: { first, _ in first })
        var storedBlobs: Set<BlobID>?
        if read.sweepsBlobs, let blobs {
            do {
                storedBlobs = try blobs.allIDs()
            } catch {
                AppLogger.history.error("Could not list saved images; unused ones are deleted at a later launch")
            }
        }
        return LoadedHistory(
            loadError: read.loadError, found: found, blobsByRecord: blobsByRecord, storedBlobs: storedBlobs)
    }

    @concurrent
    static func sortedInBackground(
        _ read: Read,
        coder: StoredEntryCoder,
        savesPasswords: Bool,
        at now: Date,
        blobs: (any BlobStore)?
    ) async -> LoadedHistory {
        sorted(read, coder: coder, savesPasswords: savesPasswords, at: now, blobs: blobs)
    }

    /// The blobs stored at load that no record references once the records with `deleted` IDs are gone.
    func orphans(deleted: Set<UUID>) -> Set<BlobID> {
        guard let storedBlobs else {
            return []
        }
        let referenced = blobsByRecord.filter { !deleted.contains($0.key) }.values.joined()
        return storedBlobs.subtracting(referenced)
    }
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
            case .waitsForKey:
                found.unopened.append(record)
            }
        }
        return found
    }

    /// Deletes the blobs that no record references.
    static func deleteOrphans(in blobs: any BlobStore, keeping referenced: Set<BlobID>) {
        do {
            delete(try blobs.allIDs().subtracting(referenced), from: blobs)
        } catch {
            AppLogger.history.error("Could not list saved images no entry uses; trying again at the next launch")
        }
    }

    /// Deletes `orphans`, blobs found to be used by no record.
    static func delete(_ orphans: Set<BlobID>, from blobs: any BlobStore) {
        guard !orphans.isEmpty else {
            return
        }
        AppLogger.history.info("Deleting \(orphans.count, privacy: .public) saved images no entry uses")
        do {
            try blobs.delete(orphans.sorted { $0.uuid.uuidString < $1.uuid.uuidString })
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

extension PersistentHistoryStore {
    /// Loads the saved history as the app does at launch: the records are fetched here, on the main actor, and
    /// decoded and checked in the background (`LoadedHistory`), so a long history does not hold up the main actor.
    /// The parameters are those of `init` and `LoadedHistory`.
    static func load(
        persistence: any HistoryPersistence,
        sealer: (any SecretSealing)?,
        savesPasswords: Bool,
        retention: RetentionPolicy = .default,
        hasher: any ContentHasher = SHA256ContentHasher(),
        now: Date = Date(),
        openError: HistoryPersistenceError? = nil,
        blobs: (any BlobStore)? = nil,
        leftovers: (any HistoryLeftovers)? = nil
    ) async -> PersistentHistoryStore {
        let read = LoadedHistory.read(from: persistence, openError: openError, leftovers: leftovers)
        let loaded = await LoadedHistory.sortedInBackground(
            read, coder: StoredEntryCoder(sealer: sealer, hasher: hasher), savesPasswords: savesPasswords, at: now,
            blobs: blobs)
        return PersistentHistoryStore(
            persistence: persistence, loaded: loaded, sealer: sealer, retention: retention, hasher: hasher, now: now,
            openError: openError, blobs: blobs, leftovers: leftovers)
    }
}
