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
/// A failed write never loses what is in memory: it is logged, shown through `storageError`, and the next change
/// writes the whole history again, so the disk catches up with memory as soon as writing works.
@MainActor
@Observable
final class PersistentHistoryStore: HistoryStore {
    /// Why the history is not, or not fully, saved. Nil while saving works. A failed write is cleared by the next
    /// successful one; a failure to open or read the saved history stays for the session.
    private(set) var storageError: HistoryPersistenceError?

    @ObservationIgnored private let memory: InMemoryHistoryStore
    @ObservationIgnored private let persistence: any HistoryPersistence
    @ObservationIgnored private let coder: StoredEntryCoder
    /// Set after a failed write: the disk no longer matches memory, so the next write replaces everything.
    @ObservationIgnored private var needsFullWrite = false

    // Reads go to the wrapped store, which is observable itself, so views that read them here are updated too.
    var entries: [ClipboardEntry] { memory.entries }
    var currentEntryID: ClipboardEntry.ID? { memory.currentEntryID }
    var retention: RetentionPolicy { memory.retention }
    var revision: Int { memory.revision }

    /// Loads the saved history. Concealed entries whose time is up at `now` are removed, then the entries
    /// `retention` does not allow, also from disk, so pass the limits the user saved, not the defaults.
    /// `openError` is what went wrong opening the store on disk, if anything, to show in `storageError`.
    init(
        persistence: any HistoryPersistence,
        sealer: (any SecretSealing)?,
        retention: RetentionPolicy = .default,
        hasher: any ContentHasher = SHA256ContentHasher(),
        now: Date = Date(),
        openError: HistoryPersistenceError? = nil
    ) {
        let coder = StoredEntryCoder(sealer: sealer, hasher: hasher)
        var storageError = openError
        var records: [StoredEntryRecord] = []
        do {
            records = try persistence.loadAll()
        } catch {
            AppLogger.history.error("Could not read the saved history; starting with an empty one")
            storageError = storageError ?? error
        }

        var loaded: [ClipboardEntry] = []
        var unreadable: [UUID] = []
        for record in records {
            switch coder.decode(record) {
            case .entry(let entry):
                loaded.append(entry)
            case .unreadable:
                unreadable.append(record.id)
            case .unsupported:
                // Saved by a newer app version: leave it for that version.
                break
            }
        }
        // Each copy moves its entry to the top with the copy's date, so newest first is by date.
        loaded.sort { $0.date > $1.date }
        let memory = InMemoryHistoryStore(restoring: loaded, at: now, retention: retention, hasher: hasher)

        self.memory = memory
        self.persistence = persistence
        self.coder = coder
        self.storageError = storageError

        let kept = Set(memory.entries.map(\.id))
        let removed = loaded.map(\.id).filter { !kept.contains($0) }
        if !unreadable.isEmpty {
            AppLogger.history.error(
                "Deleting \(unreadable.count, privacy: .public) saved entries that could not be read or decrypted")
        }
        if !(unreadable + removed).isEmpty {
            write { () throws(HistoryPersistenceError) in
                try persistence.delete(ids: unreadable + removed)
            }
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

    /// Removes every entry from memory and every record from disk, also records this version could not load.
    @discardableResult
    func clear() -> ClearResult {
        let result = memory.clear()
        if write({ () throws(HistoryPersistenceError) in try persistence.deleteAll() }) {
            // Memory and disk are both empty, so they match again.
            needsFullWrite = false
            finishWrite(sealFailed: false)
        }
        return result
    }

    func setRetention(_ policy: RetentionPolicy) {
        change { $0.setRetention(policy) }
    }

    func stats() -> HistoryStats {
        memory.stats()
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
