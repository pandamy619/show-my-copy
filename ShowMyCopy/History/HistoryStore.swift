import Foundation
import Observation

/// Where the clipboard history lives. The rest of the app talks to this protocol, so a store that keeps the history
/// on disk can replace `InMemoryHistoryStore` without changes to the monitor, the windows or the settings.
///
/// Conforming types are `@Observable` classes: SwiftUI views and models read `entries`, `currentEntryID` and
/// `retention` and update when they change. `entries` is newest first. Every change keeps the `retention` limits.
@MainActor
protocol HistoryStore: AnyObject, Observable, Sendable {
    /// Every entry, newest first.
    var entries: [ClipboardEntry] { get }

    /// The entry whose content is on the pasteboard now, or nil when the latest pasteboard change was not recorded
    /// (a skipped password, a transient, empty, too large or non-text item). The newest entry is not always current.
    var currentEntryID: ClipboardEntry.ID? { get }

    /// The limits in effect.
    var retention: RetentionPolicy { get }

    /// Adds copied content as the newest entry and makes it current. Content that is already in the history (an
    /// entry with the same content hash) moves to the top with the new date and source app. Returns the ID of the
    /// entry.
    ///
    /// A `concealed` copy hides the entry, also one that was plain before, and sets `expiresAt` when one is given.
    /// A plain copy of concealed content keeps the entry concealed with its expiry, for example after the user
    /// pasted a password into a note and copied it from there: it is still a password.
    @discardableResult
    func record(
        _ content: ClipboardContent,
        sourceApp: SourceApp?,
        at date: Date,
        concealed: Bool,
        expiresAt: Date?
    ) -> ClipboardEntry.ID

    /// The latest pasteboard change was not recorded, so no entry matches the pasteboard any more.
    func markCurrentSkipped()

    /// Hides an entry and sets when it is removed. An expiry that is already earlier stays.
    func conceal(id: ClipboardEntry.ID, expiresAt: Date)

    /// Moves every concealed entry's expiry to `date` at the latest, after the user picked a shorter lifetime.
    func limitExpiry(to date: Date)

    /// Removes concealed entries whose time is up.
    func removeExpired(at date: Date)

    /// Removes every concealed entry, after the user turned off saving passwords.
    func removeConcealed()

    func remove(id: ClipboardEntry.ID)

    /// Removes every entry.
    @discardableResult
    func clear() -> ClearResult

    /// Applies new limits, removing the entries they no longer allow.
    func setRetention(_ policy: RetentionPolicy)

    /// The number and total size of the entries.
    func stats() -> HistoryStats
}

/// What `HistoryStore.clear()` removed.
struct ClearResult: Equatable, Sendable {
    let removedCount: Int
    /// The total `byteSize` of the removed entries.
    let freedBytes: Int
}

struct HistoryStats: Equatable, Sendable {
    let count: Int
    /// The total `byteSize` of all entries.
    let totalBytes: Int
}

extension HistoryStore {
    /// The most entries kept.
    var limit: Int {
        retention.entryLimit
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

    /// Records a plain copy.
    @discardableResult
    func record(_ content: ClipboardContent, sourceApp: SourceApp?, at date: Date) -> ClipboardEntry.ID {
        record(content, sourceApp: sourceApp, at: date, concealed: false, expiresAt: nil)
    }

    func setLimit(_ newLimit: Int) {
        setRetention(retention.withEntryLimit(newLimit))
    }

    /// How many entries a new limit would remove, for the confirmation shown before applying it.
    func entriesRemoved(byLimit newLimit: Int) -> Int {
        retention.withEntryLimit(newLimit).removedCount(from: entries)
    }
}
