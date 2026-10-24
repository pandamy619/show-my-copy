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
    /// (a skipped password, a transient, empty, too large or unsupported item). The newest entry is not always
    /// current.
    var currentEntryID: ClipboardEntry.ID? { get }

    /// The limits in effect.
    var retention: RetentionPolicy { get }

    /// Changes whenever `entries` changes: an entry is added, moved, changed or removed. It stays the same when
    /// a call leaves the entries as they were. Lets views cache what they derive from the entries, such as a
    /// filtered list, without comparing every entry.
    var revision: Int { get }

    /// Adds copied content as the newest entry and makes it current. Content that is already in the history (an
    /// entry with the same content hash) moves to the top with the new date and source app. Returns the ID of the
    /// entry.
    ///
    /// A `concealed` copy hides the entry, also one that was plain before, and sets `expiresAt` when one is given.
    /// A plain copy of concealed content keeps the entry concealed with its expiry, for example after the user
    /// pasted a password into a note and copied it from there: it is still a password.
    ///
    /// The store owns the blobs of the content it keeps (image data and thumbnails, thumbnails of copied photos and
    /// videos): they are deleted with the entry. Blobs of a copy of content the history already holds are deleted
    /// at once, except the thumbnails of files the entry had none for, which the entry takes over. Content that
    /// cannot be concealed (images, files) is not recorded as a concealed copy: it and any entry holding it are
    /// removed, and the returned ID belongs to no entry.
    ///
    /// Any `stats()` and `ClearResult` count the blobs: an image's `byteSize` is its data and thumbnail, and a file
    /// entry's includes its thumbnails.
    @discardableResult
    func record(
        _ content: ClipboardContent,
        sourceApp: SourceApp?,
        at date: Date,
        concealed: Bool,
        expiresAt: Date?
    ) -> ClipboardEntry.ID

    /// Gives the files of entry `id` the thumbnails in `files` they lack, made after the entry was recorded, so the
    /// monitor does not wait for them. The entry keeps its place, date and current state; the limits apply to its
    /// new size. The store owns the thumbnails from this call on: those it does not take (the entry is gone, holds
    /// other content or has them already) are deleted at once.
    func addThumbnails(_ files: [FileReference], toEntry id: ClipboardEntry.ID)

    /// Completes an image recorded before its data was saved (`ImageReference.isSaved` is false), so the monitor
    /// does not wait for it: the entry that holds `unsaved` gets `image`, the image as saved, with its hash, size and
    /// preview. It keeps its place, date, source app and current state; the limits apply to its new size.
    ///
    /// When another entry already holds the same image, the two become one at this entry's place and the other is
    /// removed: the newer copy keeps its date and source app. With `keepsEarlierCopy`, used for the image found on
    /// the pasteboard at launch, the entry just below it keeps its own instead when it holds the image, as
    /// `markNewestCurrent(ifItHolds:)` does for other content.
    ///
    /// The store owns the blobs of `image` from this call on: those no entry uses afterwards (the entry is gone, or
    /// another entry's copy of the image is kept) are deleted.
    func completeImage(_ unsaved: ImageReference, with image: ImageReference, keepsEarlierCopy: Bool)

    /// Makes the newest entry current, without changing it, when it holds `content`. Returns its ID, or nil when
    /// the newest entry holds other content.
    ///
    /// Used for the pasteboard found at launch: it usually still holds the newest entry from the last session, and
    /// recording it again would give that entry a new date and lose its source app.
    @discardableResult
    func markNewestCurrent(ifItHolds content: ClipboardContent) -> ClipboardEntry.ID?

    /// The latest pasteboard change was not recorded, so no entry matches the pasteboard any more.
    func markCurrentSkipped()

    /// Hides an entry and sets when it is removed. An expiry that is already earlier stays. An entry that cannot be
    /// concealed (an image or files) is removed instead.
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
