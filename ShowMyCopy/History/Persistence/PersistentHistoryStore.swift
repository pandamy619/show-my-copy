import Foundation
import Observation
import os

/// Keeps the history on disk, so it survives quitting the app.
///
/// The history rules (moving repeated content to the top, concealed entries, limits, expiry) are those of
/// `InMemoryHistoryStore`, which this store wraps: it serves every read from memory and, after each call that
/// changed the entries, writes what changed to `persistence`. The current entry is not saved: after a launch
/// nothing is current until the monitor reads the pasteboard.
///
/// Concealed entries are written sealed by `sealer`. Without a sealer (the Keychain could not be used) they are
/// kept in memory only, and saved ones cannot be opened and are deleted at launch. They expire within an hour
/// anyway.
///
/// Opening a saved password needs the key, and getting the key can show a Keychain prompt. So at launch only
/// passwords that are still wanted are opened: expired ones, and all of them when saving passwords is off, are
/// deleted unopened, by what their records say in plain text.
///
/// A failed write never loses what is in memory: it is logged, shown through `storageError`, and the next change
/// writes the whole history again, so the disk catches up with memory as soon as writing works.
@MainActor
@Observable
final class PersistentHistoryStore: HistoryStore, ReportsStorageErrors, ReportsDiskUsage {
    /// Why the history is not, or not fully, saved. Nil while saving works. A failed write is cleared by the next
    /// successful one; a failure to open or read the saved history stays for the session.
    private(set) var storageError: HistoryPersistenceError?

    @ObservationIgnored private let memory: InMemoryHistoryStore
    @ObservationIgnored private let persistence: any HistoryPersistence
    @ObservationIgnored private let coder: StoredEntryCoder
    /// Where image data is kept, or nil when there is no such store: then records with blobs stay on disk unloaded.
    @ObservationIgnored private let blobs: (any BlobStore)?
    /// Whether blobs no record references may be deleted: only when `persistence` is the history saved on disk.
    /// After it failed to open, its records are unknown and their images may still be wanted.
    @ObservationIgnored private let sweepsBlobs: Bool
    /// Set after a failed write: the disk no longer matches memory, so the next write replaces everything.
    @ObservationIgnored private var needsFullWrite = false

    // Reads go to the wrapped store, which is observable itself, so views that read them here are updated too.
    var entries: [ClipboardEntry] { memory.entries }
    var currentEntryID: ClipboardEntry.ID? { memory.currentEntryID }
    var retention: RetentionPolicy { memory.retention }
    var revision: Int { memory.revision }

    /// Loads the saved history. Concealed entries whose time is up at `now`, and all of them unless
    /// `savesPasswords`, are deleted without being opened. Then the entries `retention` does not allow are removed,
    /// also from disk, so pass the limits and the password choice the user saved, not the defaults.
    /// `openError` is what went wrong opening the store on disk, if anything, to show in `storageError`.
    ///
    /// Image data lives in `blobs`. An entry whose data is gone is deleted, and blobs that no saved record
    /// references (written for an entry that was never saved, or left by a failed delete) are deleted too. Without
    /// `blobs`, records that reference blobs are left on disk and not loaded.
    init(
        persistence: any HistoryPersistence,
        sealer: (any SecretSealing)?,
        savesPasswords: Bool,
        retention: RetentionPolicy = .default,
        hasher: any ContentHasher = SHA256ContentHasher(),
        now: Date = Date(),
        openError: HistoryPersistenceError? = nil,
        blobs: (any BlobStore)? = nil
    ) {
        let coder = StoredEntryCoder(sealer: sealer, hasher: hasher)
        var storageError = openError
        var records: [StoredEntryRecord] = []
        var isLoaded = false
        do {
            records = try persistence.loadAll()
            isLoaded = true
        } catch {
            AppLogger.history.error("Could not read the saved history; starting with an empty one")
            storageError = storageError ?? error
        }

        var found = Self.sort(records, coder: coder, savesPasswords: savesPasswords, at: now, blobs: blobs)
        // Each copy moves its entry to the top with the copy's date, so newest first is by date.
        found.entries.sort { $0.date > $1.date }
        let memory = InMemoryHistoryStore(
            restoring: found.entries, at: now, retention: retention, hasher: hasher, blobs: blobs)

        self.memory = memory
        self.persistence = persistence
        self.coder = coder
        self.blobs = blobs
        self.sweepsBlobs = openError == nil
        self.storageError = storageError

        let kept = Set(memory.entries.map(\.id))
        let removed = found.entries.map(\.id).filter { !kept.contains($0) }
        if !found.unreadable.isEmpty {
            AppLogger.history.error(
                "Deleting \(found.unreadable.count, privacy: .public) saved entries that could not be read or decrypted"
            )
        }
        let deleted = found.unwanted + found.unreadable + removed
        var isDeleted = true
        if !deleted.isEmpty {
            isDeleted = write { () throws(HistoryPersistenceError) in
                try persistence.delete(ids: deleted)
            }
        }
        // Only with every record known: a sweep after a failed open or load would delete the data of every image.
        if sweepsBlobs, isLoaded, let blobs {
            let gone = isDeleted ? Set(deleted) : []
            let referenced = records.filter { !gone.contains($0.id) }.flatMap(\.blobIDs).map { BlobID(uuid: $0) }
            Self.deleteOrphans(in: blobs, keeping: Set(referenced))
        }
    }

    @discardableResult
    func record(
        _ content: ClipboardContent,
        sourceApp: SourceApp?,
        at date: Date,
        concealed: Bool,
        expiresAt: Date?
    ) -> ClipboardEntry.ID {
        change { $0.record(content, sourceApp: sourceApp, at: date, concealed: concealed, expiresAt: expiresAt) }
    }

    func addThumbnails(_ files: [FileReference], toEntry id: ClipboardEntry.ID) {
        change { $0.addThumbnails(files, toEntry: id) }
    }

    @discardableResult
    func markNewestCurrent(ifItHolds content: ClipboardContent) -> ClipboardEntry.ID? {
        memory.markNewestCurrent(ifItHolds: content)
    }

    func markCurrentSkipped() {
        memory.markCurrentSkipped()
    }

    func conceal(id: ClipboardEntry.ID, expiresAt: Date) {
        change { $0.conceal(id: id, expiresAt: expiresAt) }
    }

    func limitExpiry(to date: Date) {
        change { $0.limitExpiry(to: date) }
    }

    func removeExpired(at date: Date) {
        change { $0.removeExpired(at: date) }
    }

    func removeConcealed() {
        change { $0.removeConcealed() }
    }

    func remove(id: ClipboardEntry.ID) {
        change { $0.remove(id: id) }
    }

    /// Removes every entry from memory and every record from disk, also records this version could not load,
    /// and with them every saved image.
    @discardableResult
    func clear() -> ClearResult {
        let result = memory.clear()
        if write({ () throws(HistoryPersistenceError) in try persistence.deleteAll() }) {
            // Memory and disk are both empty, so they match again.
            needsFullWrite = false
            finishWrite(sealFailed: false)
            if sweepsBlobs, let blobs {
                // No record is left, so no blob is used: also those of records this version did not load.
                Self.deleteOrphans(in: blobs, keeping: [])
            }
        }
        return result
    }

    func setRetention(_ policy: RetentionPolicy) {
        change { $0.setRetention(policy) }
    }

    func stats() -> HistoryStats {
        memory.stats()
    }

    /// How many bytes the saved history takes on disk, saved images included, or nil when it is kept in memory
    /// only.
    func storedBytes() -> Int64? {
        persistence.storedBytes().map { $0 + (blobs?.totalBytes() ?? 0) }
    }

    // MARK: - Writing

    /// Runs `body` on the history in memory, then writes what it changed.
    private func change<Result>(_ body: (InMemoryHistoryStore) -> Result) -> Result {
        let revisionBefore = memory.revision
        let before = memory.entries
        let result = body(memory)
        // The revision changes with every change to the entries, and only then: most polls change nothing.
        if memory.revision != revisionBefore {
            saveChanges(from: before)
        }
        return result
    }

    private func saveChanges(from before: [ClipboardEntry]) {
        guard !needsFullWrite else {
            saveEverything()
            return
        }
        var sealFailed = false
        let previous = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(memory.entries.map(\.id))
        var deleted = before.map(\.id).filter { !currentIDs.contains($0) }
        var inserted: [StoredEntryRecord] = []
        var updated: [StoredEntryRecord] = []
        for entry in memory.entries where previous[entry.id] != entry {
            let isNew = previous[entry.id] == nil
            if let record = storedRecord(for: entry, sealFailed: &sealFailed) {
                if isNew {
                    inserted.append(record)
                } else {
                    updated.append(record)
                }
            } else if !isNew {
                // Now kept in memory only, such as an entry concealed without a sealer: its old record goes.
                deleted.append(entry.id)
            }
        }

        let saved = write { () throws(HistoryPersistenceError) in
            if !deleted.isEmpty {
                try persistence.delete(ids: deleted)
            }
            if !inserted.isEmpty {
                try persistence.insert(inserted)
            }
            if !updated.isEmpty {
                try persistence.update(updated)
            }
        }
        if saved {
            finishWrite(sealFailed: sealFailed)
        }
    }

    /// Replaces everything on disk with the history in memory, after a failed write left the two apart.
    private func saveEverything() {
        var sealFailed = false
        let records = memory.entries.compactMap { storedRecord(for: $0, sealFailed: &sealFailed) }
        let saved = write { () throws(HistoryPersistenceError) in
            try persistence.deleteAll()
            try persistence.insert(records)
        }
        if saved {
            needsFullWrite = false
            finishWrite(sealFailed: sealFailed)
        }
    }

    /// The record to write for `entry`, or nil when it is kept in memory only. A failure to seal was logged by the
    /// coder and is noted in `sealFailed`.
    private func storedRecord(for entry: ClipboardEntry, sealFailed: inout Bool) -> StoredEntryRecord? {
        do {
            return try coder.record(for: entry)
        } catch {
            sealFailed = true
            return nil
        }
    }

    private func finishWrite(sealFailed: Bool) {
        if sealFailed {
            storageError = .sealFailed
        } else if storageError?.isWriteFailure == true {
            storageError = nil
        }
    }

    /// Runs one write. On failure logs it, reports it and makes the next write replace everything.
    @discardableResult
    private func write(_ operation: () throws(HistoryPersistenceError) -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            AppLogger.history.error("Could not save a change to the history; it is kept in memory")
            needsFullWrite = true
            if storageError == nil || storageError?.isWriteFailure == true {
                storageError = error
            }
            return false
        }
    }
}

/// What `PersistentHistoryStore.sort` found in the saved records.
private struct FoundRecords {
    var entries: [ClipboardEntry] = []
    /// Damaged, not to be opened, or an image whose data or thumbnail is gone: deleted.
    var unreadable: [UUID] = []
    /// Passwords that are expired or no longer saved: deleted unopened.
    var unwanted: [UUID] = []
}

// MARK: - Loading

extension PersistentHistoryStore {
    /// Sorts the saved records into entries to load and records to delete. Records from a newer app version, and
    /// records with blobs while there is no blob store, are in neither: they stay on disk.
    private static func sort(
        _ records: [StoredEntryRecord],
        coder: StoredEntryCoder,
        savesPasswords: Bool,
        at now: Date,
        blobs: (any BlobStore)?
    ) -> FoundRecords {
        var found = FoundRecords()
        for record in records {
            // Decided before opening: opening asks for the key, which can show a Keychain prompt.
            if isUnwantedPassword(record, savesPasswords: savesPasswords, at: now, coder: coder) {
                found.unwanted.append(record.id)
                continue
            }
            var missing: Set<BlobID> = []
            if !record.blobIDs.isEmpty, coder.supports(record) {
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
            case .unsupported:
                // Saved by a newer app version: leave it for that version.
                break
            }
        }
        return found
    }

    /// Deletes the blobs that no record references.
    private static func deleteOrphans(in blobs: any BlobStore, keeping referenced: Set<BlobID>) {
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
    /// Records from a newer app version are left to that version.
    private static func isUnwantedPassword(
        _ record: StoredEntryRecord,
        savesPasswords: Bool,
        at now: Date,
        coder: StoredEntryCoder
    ) -> Bool {
        guard record.isConcealed, coder.supports(record) else {
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
