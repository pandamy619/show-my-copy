import Foundation
import Observation

@MainActor
@Observable
final class ClipboardHistory {
    nonisolated static let defaultLimit = 50
    nonisolated static let limitRange = 10...1000

    private(set) var entries: [ClipboardEntry] = []
    private(set) var limit: Int
    /// The entry whose text is on the pasteboard now, or nil when the latest pasteboard change was not recorded
    /// (a skipped password, a transient, empty, too large or non-text item). The newest entry is not always current.
    private(set) var currentEntryID: ClipboardEntry.ID?
    private let hasher: any ContentHasher

    init(limit: Int = ClipboardHistory.defaultLimit, hasher: any ContentHasher = SHA256ContentHasher()) {
        self.limit = Self.clamped(limit)
        self.hasher = hasher
    }

    /// Adds copied content as the newest entry and makes it current. Content that is already in the history (an
    /// entry with the same content hash) moves to the top. Returns the ID of the entry.
    ///
    /// A `concealed` copy hides the entry, also one that was plain before. A plain copy of concealed content keeps
    /// the entry concealed with its expiry, for example after the user pasted a password into a note and copied it
    /// from there: it is still a password.
    @discardableResult
    func record(
        _ content: ClipboardContent,
        sourceApp: SourceApp?,
        at date: Date,
        concealed: Bool = false,
        expiresAt: Date? = nil
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

    /// Records copied text. See `record(_:sourceApp:at:concealed:expiresAt:)`.
    @discardableResult
    func record(
        text: String,
        sourceApp: SourceApp?,
        at date: Date,
        concealed: Bool = false,
        expiresAt: Date? = nil
    ) -> ClipboardEntry.ID {
        record(.text(text), sourceApp: sourceApp, at: date, concealed: concealed, expiresAt: expiresAt)
    }

    /// Hides an entry and sets when it is removed. An expiry that is already earlier stays.
    func conceal(id: ClipboardEntry.ID, expiresAt: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }
        entries[index].isConcealed = true
        entries[index].expiresAt = min(entries[index].expiresAt ?? expiresAt, expiresAt)
    }

    /// Moves every concealed entry's expiry to `date` at the latest, after the user picked a shorter lifetime.
    func limitExpiry(to date: Date) {
        for index in entries.indices where entries[index].isConcealed {
            entries[index].expiresAt = min(entries[index].expiresAt ?? date, date)
        }
    }

    /// Removes concealed entries whose time is up.
    func removeExpired(at date: Date) {
        removeEntries { entry in
            guard entry.isConcealed, let expiresAt = entry.expiresAt else {
                return false
            }
            return expiresAt <= date
        }
    }

    /// Removes every concealed entry, after the user turned off saving passwords.
    func removeConcealed() {
        removeEntries(where: \.isConcealed)
    }

    func remove(id: ClipboardEntry.ID) {
        removeEntries { $0.id == id }
    }

    /// The latest pasteboard change was not recorded, so no entry matches the pasteboard any more.
    func markCurrentSkipped() {
        currentEntryID = nil
    }

    func setLimit(_ newLimit: Int) {
        limit = Self.clamped(newLimit)
        trim()
    }

    /// How many entries a new limit would remove, for the confirmation shown before applying it.
    func entriesRemoved(byLimit newLimit: Int) -> Int {
        max(0, entries.count - Self.clamped(newLimit))
    }

    func clear() {
        entries.removeAll()
        currentEntryID = nil
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
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        forgetMissingCurrentEntry()
    }

    private func forgetMissingCurrentEntry() {
        if let currentEntryID, !entries.contains(where: { $0.id == currentEntryID }) {
            self.currentEntryID = nil
        }
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, limitRange.lowerBound), limitRange.upperBound)
    }
}
