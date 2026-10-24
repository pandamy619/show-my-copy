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
/// Concealed entries are written sealed by `sealer`. Without one (no Keychain) they are kept in memory only, like an
/// image whose data is not saved yet, and saved ones cannot be opened and are deleted at launch.
///
/// Opening a saved password needs the key, and getting the key can show a Keychain prompt. So at launch only
/// passwords that are still wanted are opened: expired ones, and all of them when saving passwords is off, are
/// deleted unopened, by what their records say in plain text.
///
/// Each write is one transaction (`HistoryPersistence.apply`), so a failed one leaves the disk as it was. It never
/// loses what is in memory either: it is logged, shown through `storageError`, and the next change writes what the
/// failed ones did not, so the disk catches up with memory as soon as writing works. A write touches only the
/// records of entries this session loaded or made, never the others on disk: images left unloaded
/// without a blob store, or the whole saved history when it could not be read. Only Clear History deletes those.
@MainActor
@Observable
final class PersistentHistoryStore: HistoryStore, ReportsStorageErrors, ReportsDiskUsage, KeepsDamagedHistory {
    /// Why the history is not, or not fully, saved. Nil while saving works. A failed write is cleared by the next
    /// successful one; a failure to open or read the saved history stays for the session.
    private(set) var storageError: HistoryPersistenceError?
    /// The size of a damaged copy of a history (see `HistoryLeftovers`), or nil when there is none. Read at launch
    /// and after deleting it, so views never read the file system for it.
    private(set) var damagedHistoryBytes: Int64?

    @ObservationIgnored private let memory: InMemoryHistoryStore
    @ObservationIgnored private let persistence: any HistoryPersistence
    @ObservationIgnored private let coder: StoredEntryCoder
    /// Where image data is kept, or nil when there is no such store: then records with blobs stay on disk unloaded.
    @ObservationIgnored private let blobs: (any BlobStore)?
    /// Whether blobs no record references may be deleted: only when `persistence` is the history saved on disk and
    /// no other copy of a history is left. After the store failed to open, its records are unknown, and a damaged
    /// copy may reference any image, so their images may still be wanted.
    @ObservationIgnored private let sweepsBlobs: Bool
    /// Whether every store that may reference blobs is either `persistence` or in `leftovers`: then, once both are
    /// deleted, no blob is used. Not after the store failed to open without a folder to find it in.
    @ObservationIgnored private let knowsEveryStore: Bool
    @ObservationIgnored private let leftovers: (any HistoryLeftovers)?
    /// The entries whose last write failed: the next write saves them as they are in memory then, or deletes their
    /// records when they are gone.
    @ObservationIgnored private var unsaved: Set<ClipboardEntry.ID> = []
    /// Set while a Clear History has not reached the disk: the next write deletes every record first.
    @ObservationIgnored private var clearPending = false

    // Reads go to the wrapped store, which is observable itself, so views that read them here are updated too.
    var entries: [ClipboardEntry] { memory.entries }
    var currentEntryID: ClipboardEntry.ID? { memory.currentEntryID }
    var retention: RetentionPolicy { memory.retention }
    var revision: Int { memory.revision }

    /// Loads the saved history. Concealed entries whose time is up at `now`, and all of them unless
    /// `savesPasswords`, are deleted without being opened. Then the entries `retention` does not allow are removed,
    /// also from disk, so pass the limits and the password choice the user saved, not the defaults.
    /// `openError` is what went wrong opening the store on disk, if anything, to show in `storageError`.
    /// `leftovers` are the files of a saved history this session does not use, such as a damaged copy.
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
        blobs: (any BlobStore)? = nil,
        leftovers: (any HistoryLeftovers)? = nil
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

        var found = SavedRecords.sort(records, coder: coder, savesPasswords: savesPasswords, at: now, blobs: blobs)
        // Each copy moves its entry to the top with the copy's date, so newest first is by date.
        found.entries.sort { $0.date > $1.date }
        let memory = InMemoryHistoryStore(
            restoring: found.entries, at: now, retention: retention, hasher: hasher, blobs: blobs)

        self.memory = memory
        self.persistence = persistence
        self.coder = coder
        self.blobs = blobs
        self.sweepsBlobs = openError == nil && leftovers?.hasFiles() != true
        self.knowsEveryStore = openError == nil || leftovers != nil
        self.leftovers = leftovers
        self.damagedHistoryBytes = leftovers?.damagedCopyBytes()
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
            isDeleted = write(StoredChange(deleted: deleted), covering: Set(deleted))
        }
        // Only with every record known: a sweep after a failed open or load, or while a damaged copy is kept, would
        // delete the data of images that may still be wanted.
        if sweepsBlobs, isLoaded, let blobs {
            let gone = isDeleted ? Set(deleted) : []
            let referenced = records.filter { !gone.contains($0.id) }.flatMap(\.blobIDs).map { BlobID(uuid: $0) }
            SavedRecords.deleteOrphans(in: blobs, keeping: Set(referenced))
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

    func completeImage(_ unsaved: ImageReference, with image: ImageReference, keepsEarlierCopy: Bool) {
        change { $0.completeImage(unsaved, with: image, keepsEarlierCopy: keepsEarlierCopy) }
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

    /// Removes every entry from memory and every record from disk, also records that were not loaded, any copy
    /// of a history that could not be opened, or the store itself while it cannot be opened (`HistoryLeftovers`),
    /// and with them every saved image. When deleting the records fails, the next write tries again.
    @discardableResult
    func clear() -> ClearResult {
        let result = memory.clear()
        // Every entry is gone, so what earlier writes left unsaved is deleted with the rest.
        unsaved = []
        clearPending = true
        let cleared = write(StoredChange(), covering: [])
        if cleared {
            // Memory and disk are both empty, so they match again.
            finishWrite(sealFailed: false)
        }
        let leftoversDeleted = leftovers?.deleteAll() ?? true
        damagedHistoryBytes = leftovers?.damagedCopyBytes()
        if cleared, leftoversDeleted, knowsEveryStore, let blobs {
            // No record is left anywhere, so no blob is used: also those of records that were not loaded.
            SavedRecords.deleteOrphans(in: blobs, keeping: [])
        }
        return result
    }

    /// Deletes the copy of a history that could not be opened, for example when saving passwords is turned off:
    /// it may hold passwords, encrypted with the key in the Keychain, that nothing else would delete. A store
    /// that could not be opened stays: loading it later deletes its passwords when saving them is off.
    func deleteDamagedHistory() {
        guard let leftovers, damagedHistoryBytes != nil else {
            return
        }
        leftovers.deleteDamagedCopy()
        damagedHistoryBytes = leftovers.damagedCopyBytes()
    }

    func setRetention(_ policy: RetentionPolicy) {
        change { $0.setRetention(policy) }
    }

    func stats() -> HistoryStats {
        memory.stats()
    }

    /// How many bytes the saved history takes on disk, saved images and `HistoryLeftovers` included, or nil when
    /// nothing is saved in files.
    func storedBytes() -> Int64? {
        let stores = [persistence.storedBytes(), leftovers?.totalBytes()].compactMap { $0 }
        guard !stores.isEmpty else {
            return nil
        }
        return stores.reduce(0, +) + (blobs?.totalBytes() ?? 0)
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
        let previous = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(memory.entries.map(\.id))
        var changed = Set(before.map(\.id).filter { !currentIDs.contains($0) })
        for entry in memory.entries where previous[entry.id] != entry {
            changed.insert(entry.id)
        }
        saveEntries(changed)
    }

    /// Writes the entries with these IDs as they are in memory now, with those earlier writes did not save: an entry
    /// in memory is saved, the record of one gone or kept in memory only (an image not saved yet) is deleted. Only
    /// these records are touched, so records this session did not load stay as they are.
    private func saveEntries(_ ids: Set<ClipboardEntry.ID>) {
        let pending = ids.union(unsaved)
        var sealFailed = false
        var change = StoredChange()
        var inMemory: Set<ClipboardEntry.ID> = []
        for entry in memory.entries where pending.contains(entry.id) && entry.content.image?.isSaved != false {
            inMemory.insert(entry.id)
            if let record = storedRecord(for: entry, sealFailed: &sealFailed) {
                change.saved.append(record)
            } else {
                // Kept in memory only, such as an entry concealed without a sealer: an old record goes.
                change.deleted.append(entry.id)
            }
        }
        change.deleted += pending.subtracting(inMemory).sorted { $0.uuidString < $1.uuidString }
        if write(change, covering: pending) {
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

    /// Writes `change` in one transaction, deleting every record first while a Clear History has not reached the
    /// disk. `pending` are the entries it covers: when it fails, they are written with the next change. A failure
    /// is logged and reported.
    @discardableResult
    private func write(_ change: StoredChange, covering pending: Set<ClipboardEntry.ID>) -> Bool {
        var change = change
        change.deletesAll = change.deletesAll || clearPending
        guard !change.isEmpty else {
            return true
        }
        do {
            try persistence.apply(change)
        } catch {
            AppLogger.history.error("Could not save a change to the history; it is kept in memory")
            unsaved.formUnion(pending)
            if storageError == nil || storageError?.isWriteFailure == true {
                storageError = error
            }
            return false
        }
        unsaved.subtract(pending)
        if change.deletesAll {
            clearPending = false
        }
        return true
    }
}
