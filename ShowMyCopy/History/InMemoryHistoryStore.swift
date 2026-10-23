import Foundation
import Observation

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

    init(retention: RetentionPolicy = .default, hasher: any ContentHasher = SHA256ContentHasher()) {
        self.retention = retention
        self.hasher = hasher
    }

    /// Starts with `entries`, newest first, such as a history saved before the app quit. Removes the concealed
    /// entries whose time is up at `date` first, then the entries `retention` does not allow, so an expired
    /// password does not push out an entry that fits once it is gone. No entry is current: nothing says yet what is
    /// on the pasteboard.
    init(
        restoring entries: [ClipboardEntry],
        at date: Date,
        retention: RetentionPolicy = .default,
        hasher: any ContentHasher = SHA256ContentHasher()
    ) {
        self.entries = entries
        self.retention = retention
        self.hasher = hasher
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
        var entry: ClipboardEntry
        if let index = entries.firstIndex(where: { $0.contentHash == contentHash }) {
            entry = entries.remove(at: index)
            entry.date = date
            entry.sourceApp = sourceApp
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

    func conceal(id: ClipboardEntry.ID, expiresAt: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
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
            entries.removeAll()
            entriesChanged()
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
        entries.removeAll(where: shouldRemove)
        entriesChanged()
        forgetMissingCurrentEntry()
    }

    private func trim() {
        let kept = retention.kept(entries)
        // Avoid a change notification to observers when nothing is removed, which is the case on almost every copy.
        if kept.count != entries.count {
            entries = kept
            entriesChanged()
        }
        forgetMissingCurrentEntry()
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
