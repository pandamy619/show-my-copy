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
    private let hasher: any ContentHasher

    init(retention: RetentionPolicy = .default, hasher: any ContentHasher = SHA256ContentHasher()) {
        self.retention = retention
        self.hasher = hasher
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
            entry = ClipboardEntry(content: content, contentHash: contentHash, date: date, sourceApp: sourceApp)
        }
        if concealed {
            entry.isConcealed = true
            entry.expiresAt = expiresAt ?? entry.expiresAt
        }
        entries.insert(entry, at: 0)
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
    }

    func limitExpiry(to date: Date) {
        for index in entries.indices where entries[index].isConcealed {
            entries[index].expiresAt = min(entries[index].expiresAt ?? date, date)
        }
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
        entries.removeAll()
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
        forgetMissingCurrentEntry()
    }

    private func trim() {
        let kept = retention.kept(entries)
        // Avoid a change notification to observers when nothing is removed, which is the case on almost every copy.
        if kept.count != entries.count {
            entries = kept
        }
        forgetMissingCurrentEntry()
    }

    private func forgetMissingCurrentEntry() {
        if let currentEntryID, !entries.contains(where: { $0.id == currentEntryID }) {
            self.currentEntryID = nil
        }
    }
}
