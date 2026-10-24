import Foundation
import Observation
import os

/// The name the history had before `HistoryStore`. Kept so existing call sites and tests read as before.
typealias ClipboardHistory = InMemoryHistoryStore

/// Keeps the history in memory only: it is gone when the app quits.
@MainActor
@Observable
final class InMemoryHistoryStore: HistoryStore {
    /// Kept for older call sites. `RetentionPolicy` owns the limits.
    nonisolated static let defaultLimit = RetentionPolicy.defaultEntryLimit
    nonisolated static let limitRange = RetentionPolicy.entryLimitRange

    private(set) var entries: [ClipboardEntry] = []
    private(set) var retention: RetentionPolicy
    private(set) var currentEntryID: ClipboardEntry.ID?
    private(set) var revision = 0
    private let hasher: any ContentHasher
    /// Where image data is kept. Every entry removed from the history takes its blobs with it. Nil when the
    /// history holds no content with blobs.
    private let blobs: (any BlobStore)?

    init(
        retention: RetentionPolicy = .default,
        hasher: any ContentHasher = SHA256ContentHasher(),
        blobs: (any BlobStore)? = nil
    ) {
        self.retention = retention
        self.hasher = hasher
        self.blobs = blobs
    }

    /// Starts with `entries`, newest first, such as a history saved before the app quit. Removes the concealed
    /// entries whose time is up at `date` first, then the entries `retention` does not allow, so an expired
    /// password does not push out an entry that fits once it is gone. No entry is current: nothing says yet what is
    /// on the pasteboard.
    init(
        restoring entries: [ClipboardEntry],
        at date: Date,
        retention: RetentionPolicy = .default,
        hasher: any ContentHasher = SHA256ContentHasher(),
        blobs: (any BlobStore)? = nil
    ) {
        self.entries = entries
        self.retention = retention
        self.hasher = hasher
        self.blobs = blobs
        removeExpired(at: date)
        trim()
    }

    convenience init(limit: Int) {
        self.init(retention: RetentionPolicy(entryLimit: limit))
    }

    @discardableResult
    func record(
        _ content: ClipboardContent,
        sourceApp: SourceApp?,
        at date: Date,
        concealed: Bool,
        expiresAt: Date?
    ) -> ClipboardEntry.ID {
        let contentHash = hasher.hash(content)
        if concealed, !content.canBeConcealed {
            return dropSecret(content, contentHash: contentHash)
        }
        var entry: ClipboardEntry
        if let index = entries.firstIndex(where: { $0.contentHash == contentHash }) {
            entry = entries.remove(at: index)
            // Files copied again may bring the thumbnails the first copy could not make, such as for an entry from
            // before thumbnails or after a timeout. Those it has stay.
            let filled = entry.content.addingMissingThumbnails(from: content)
            if filled != entry.content {
                entry = entry.replacingContent(filled)
            }
            entry.date = date
            entry.sourceApp = sourceApp
            // The entry keeps its own content, so blobs written for this copy of the same content are not needed.
            let kept = Set(entry.content.blobIDs)
            deleteBlobs(content.blobIDs.filter { !kept.contains($0) })
        } else {
            // Made concealed right away, so no search key is ever made from a password.
            entry = ClipboardEntry(
                content: content, contentHash: contentHash, date: date, sourceApp: sourceApp, isConcealed: concealed)
        }
        if concealed {
            entry.isConcealed = true
            entry.expiresAt = expiresAt ?? entry.expiresAt
        }
        entries.insert(entry, at: 0)
        entriesChanged()
        currentEntryID = entry.id
        trim()
        return entry.id
    }

    func addThumbnails(_ files: [FileReference], toEntry id: ClipboardEntry.ID) {
        let offered = ClipboardContent.files(files)
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            deleteBlobs(offered.blobIDs)
            return
        }
        let filled = entries[index].content.addingMissingThumbnails(from: offered)
        let taken = Set(filled.blobIDs)
        deleteBlobs(offered.blobIDs.filter { !taken.contains($0) })
        guard filled != entries[index].content else {
            return
        }
        entries[index] = entries[index].replacingContent(filled)
        entriesChanged()
        trim()
    }

    /// An entry whose content cannot be concealed (an image or files) is removed instead: a secret is never kept
    /// as an image file or a file reference.
    func conceal(id: ClipboardEntry.ID, expiresAt: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard entries[index].content.canBeConcealed else {
            AppLogger.history.debug("Removed an entry that cannot be kept as a password")
            remove(id: id)
            return
        }
        entries[index].isConcealed = true
        entries[index].expiresAt = min(entries[index].expiresAt ?? expiresAt, expiresAt)
        entriesChanged()
    }

    func limitExpiry(to date: Date) {
        guard entries.contains(where: \.isConcealed) else {
            return
        }
        for index in entries.indices where entries[index].isConcealed {
            entries[index].expiresAt = min(entries[index].expiresAt ?? date, date)
        }
        entriesChanged()
    }

    func removeExpired(at date: Date) {
        removeEntries { entry in
            guard entry.isConcealed, let expiresAt = entry.expiresAt else {
                return false
            }
            return expiresAt <= date
        }
    }

    func removeConcealed() {
        removeEntries(where: \.isConcealed)
    }

    func remove(id: ClipboardEntry.ID) {
        removeEntries { $0.id == id }
    }

    @discardableResult
    func markNewestCurrent(ifItHolds content: ClipboardContent) -> ClipboardEntry.ID? {
        guard let newest = entries.first, newest.contentHash == hasher.hash(content) else {
            return nil
        }
        if currentEntryID != newest.id {
            currentEntryID = newest.id
        }
        return newest.id
    }

    func markCurrentSkipped() {
        currentEntryID = nil
    }

    func setRetention(_ policy: RetentionPolicy) {
        retention = policy
        trim()
    }

    @discardableResult
    func clear() -> ClearResult {
        let stats = stats()
        if !entries.isEmpty {
            let removed = entries
            entries.removeAll()
            entriesChanged()
            deleteBlobs(of: removed)
        }
        currentEntryID = nil
        return ClearResult(removedCount: stats.count, freedBytes: stats.totalBytes)
    }

    func stats() -> HistoryStats {
        HistoryStats(count: entries.count, totalBytes: entries.reduce(0) { $0 + $1.byteSize })
    }

    private func removeEntries(where shouldRemove: (ClipboardEntry) -> Bool) {
        // Avoid a change notification to observers when nothing matches, which is the case on almost every poll.
        guard entries.contains(where: shouldRemove) else {
            return
        }
        let removed = entries.filter(shouldRemove)
        entries.removeAll(where: shouldRemove)
        entriesChanged()
        forgetMissingCurrentEntry()
        deleteBlobs(of: removed)
    }

    private func trim() {
        let kept = retention.kept(entries)
        // Avoid a change notification to observers when nothing is removed, which is the case on almost every copy.
        if kept.count != entries.count {
            let keptIDs = Set(kept.map(\.id))
            let removed = entries.filter { !keptIDs.contains($0.id) }
            entries = kept
            entriesChanged()
            deleteBlobs(of: removed)
        }
        forgetMissingCurrentEntry()
    }

    /// Content that turned out to be a secret but cannot be concealed is not kept: its new blobs and any entry that
    /// already holds it go. Returns an ID that no entry has.
    private func dropSecret(_ content: ClipboardContent, contentHash: ContentHash) -> ClipboardEntry.ID {
        AppLogger.history.debug("Did not keep a secret that cannot be kept as a password")
        let existingBlobs = Set(entries.filter { $0.contentHash == contentHash }.flatMap(\.content.blobIDs))
        removeEntries { $0.contentHash == contentHash }
        deleteBlobs(content.blobIDs.filter { !existingBlobs.contains($0) })
        currentEntryID = nil
        return UUID()
    }

    private func deleteBlobs(of removed: [ClipboardEntry]) {
        deleteBlobs(removed.flatMap(\.content.blobIDs))
    }

    /// Deletes blobs no entry needs any more. A failure is logged by the blob store and leaves the files for the
    /// sweep at the next launch; the entries are gone either way.
    private func deleteBlobs(_ ids: [BlobID]) {
        guard !ids.isEmpty, let blobs else {
            return
        }
        do {
            try blobs.delete(ids)
        } catch {
            AppLogger.history.error("Some image data of removed entries is left for the next launch")
        }
    }

    /// Call after every change to `entries`.
    private func entriesChanged() {
        revision &+= 1
    }

    private func forgetMissingCurrentEntry() {
        if let currentEntryID, !entries.contains(where: { $0.id == currentEntryID }) {
            self.currentEntryID = nil
        }
    }
}
