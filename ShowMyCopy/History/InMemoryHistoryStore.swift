import Foundation
import Observation
import os

/// Keeps the history in memory only: it is gone when the app quits.
@MainActor
@Observable
final class InMemoryHistoryStore: HistoryStore {
    private(set) var entries: [ClipboardEntry] = []
    private(set) var retention: RetentionPolicy
    private(set) var currentEntryID: ClipboardEntry.ID?
    private(set) var revision = 0
    private let hasher: any ContentHasher
    /// Where image data is kept. Every entry removed from the history takes its blobs with it. Nil when the
    /// history holds no content with blobs.
    private let blobs: (any BlobStore)?
    /// The time the age limit is measured against when the history changes. `removeExpired(at:)` is given its time.
    private let now: @MainActor () -> Date

    init(
        retention: RetentionPolicy = .default,
        hasher: any ContentHasher = SHA256ContentHasher(),
        blobs: (any BlobStore)? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.retention = retention
        self.hasher = hasher
        self.blobs = blobs
        self.now = now
    }

    /// Starts with `entries`, newest first, such as a history saved before the app quit. Removes the concealed
    /// entries whose time is up at `date` and the entries past the age limit first, then the entries the other
    /// limits do not allow, so an expired entry does not push out one that fits once it is gone. No entry is
    /// current: nothing says yet what is on the pasteboard.
    init(
        restoring entries: [ClipboardEntry],
        at date: Date,
        retention: RetentionPolicy = .default,
        hasher: any ContentHasher = SHA256ContentHasher(),
        blobs: (any BlobStore)? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.entries = entries
        self.retention = retention
        self.hasher = hasher
        self.blobs = blobs
        self.now = now
        removeExpired(at: date)
        trim(at: date)
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
            if entries[index].isPinned, !concealed {
                return recordAgain(content, pinnedAt: index)
            }
            entry = entries.remove(at: index)
            // Files copied again may bring the thumbnails the first copy could not make, such as for an entry from
            // before thumbnails or after a timeout. Those it has stay.
            let filled = entry.content.addingMissingFileDetails(from: content)
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

    func addFileDetails(_ files: [FileReference], toEntry id: ClipboardEntry.ID) {
        let offered = ClipboardContent.files(files)
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            deleteBlobs(offered.blobIDs)
            return
        }
        let filled = entries[index].content.addingMissingFileDetails(from: offered)
        let taken = Set(filled.blobIDs)
        deleteBlobs(offered.blobIDs.filter { !taken.contains($0) })
        guard filled != entries[index].content else {
            return
        }
        entries[index] = entries[index].replacingContent(filled)
        entriesChanged()
        trim()
    }

    func completeImage(_ unsaved: ImageReference, with image: ImageReference, keepsEarlierCopy: Bool) {
        // Whatever of these no entry uses at the end is deleted.
        var released = Set(unsaved.blobIDs + image.blobIDs)
        guard let index = entries.firstIndex(where: { $0.content.image == unsaved }) else {
            deleteUnused(released)
            return
        }
        let content = ClipboardContent.image(image)
        var completed = entries[index].replacingContent(content, contentHash: hasher.hash(content))
        var merged = [entries[index].id]
        let other = entries.firstIndex { $0.contentHash == completed.contentHash }
        // A pinned copy of the image keeps its place, as when pinned content is copied again (`record`).
        let keepsPinnedCopy = other.map { entries[$0].isPinned && !completed.isPinned } == true
        if let other {
            merged.append(entries[other].id)
            released.formUnion(entries[other].content.blobIDs)
            // The image on the pasteboard at launch is the entry from before: nothing says it was copied again.
            if keepsPinnedCopy || (keepsEarlierCopy && other == index + 1) {
                completed = entries[other]
            }
        }
        let wasCurrent = currentEntryID.map(merged.contains) == true
        if keepsPinnedCopy {
            entries.remove(at: index)
        } else {
            entries[index] = completed
            if let other {
                entries.remove(at: other)
            }
        }
        entriesChanged()
        if wasCurrent {
            currentEntryID = completed.id
        }
        trim()
        deleteUnused(released)
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

    /// Runs on every poll, so it changes nothing, and walks the entries without copying them, while nothing expired.
    func removeExpired(at date: Date) {
        removeEntries { entry in
            guard entry.isConcealed, let expiresAt = entry.expiresAt else {
                return false
            }
            return expiresAt <= date
        }
        if entries.contains(where: { retention.isPastMaxAge($0, at: date) }) {
            trim(at: date)
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
        let contentHash = hasher.hash(content)
        // Pinned entries are newer by the time they were pinned, not by a copy.
        guard let newest = entries.first(where: { !$0.isPinned || $0.contentHash == contentHash }),
            newest.contentHash == contentHash
        else {
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

    /// Removes the entries `retention` does not allow at `date`, by default now.
    private func trim(at date: Date? = nil) {
        let kept = retention.kept(entries, at: date ?? now())
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

    /// Deletes those of `ids` that no entry uses.
    private func deleteUnused(_ ids: Set<BlobID>) {
        let used = Set(entries.flatMap(\.content.blobIDs))
        deleteBlobs(ids.subtracting(used).sorted { $0.uuid.uuidString < $1.uuid.uuidString })
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

extension InMemoryHistoryStore {
    /// Adds entries saved before that could not be loaded with the others, such as saved passwords that waited for
    /// their key, or entries removed earlier in this session (see `HistoryStore.restore(_:)`), each at its place by
    /// date. An entry whose ID or content is in the history already is not added: the one in the history was recorded
    /// in this session and may be current. Nothing becomes current, and the limits apply afterwards.
    func restore(_ restored: [ClipboardEntry]) {
        var ids = Set(entries.map(\.id))
        var hashes = Set(entries.map(\.contentHash))
        var added = false
        for entry in restored.sorted(by: { $0.date > $1.date }) {
            guard !ids.contains(entry.id), !hashes.contains(entry.contentHash) else {
                continue
            }
            let index = entries.firstIndex { $0.date < entry.date } ?? entries.endIndex
            entries.insert(entry, at: index)
            ids.insert(entry.id)
            hashes.insert(entry.contentHash)
            added = true
        }
        guard added else {
            return
        }
        entriesChanged()
        trim()
    }
}

// MARK: - Pinning and clearing

extension InMemoryHistoryStore {
    func setPinned(_ isPinned: Bool, id: ClipboardEntry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isPinned != isPinned,
            !entries[index].isConcealed
        else {
            return
        }
        var entry = entries.remove(at: index)
        entry.isPinned = isPinned
        // Pinned: its place among the pinned entries. Unpinned: the top, as if just copied.
        entry.date = now()
        entries.insert(entry, at: entries.firstIndex { $0.date <= entry.date } ?? entries.endIndex)
        entriesChanged()
        trim()
    }

    @discardableResult
    func clear(keepingPinned: Bool) -> ClearResult {
        let removed = keepingPinned ? entries.filter { !$0.isPinned } : entries
        if !removed.isEmpty {
            entries = keepingPinned ? entries.filter(\.isPinned) : []
            entriesChanged()
            deleteBlobs(of: removed)
        }
        if keepingPinned {
            forgetMissingCurrentEntry()
        } else {
            currentEntryID = nil
        }
        return ClearResult(removedCount: removed.count, freedBytes: removed.reduce(0) { $0 + $1.byteSize })
    }

    /// A copy of the content of the pinned entry at `index`: the entry becomes current and keeps its place, date and
    /// source app, so the pinned entries stay in the order they were pinned in. Files may get the thumbnails they
    /// lacked; the copy's other blobs are not needed.
    private func recordAgain(_ content: ClipboardContent, pinnedAt index: Int) -> ClipboardEntry.ID {
        let filled = entries[index].content.addingMissingFileDetails(from: content)
        if filled != entries[index].content {
            entries[index] = entries[index].replacingContent(filled)
            entriesChanged()
        }
        let kept = Set(entries[index].content.blobIDs)
        deleteBlobs(content.blobIDs.filter { !kept.contains($0) })
        let id = entries[index].id
        currentEntryID = id
        trim()
        return id
    }
}
