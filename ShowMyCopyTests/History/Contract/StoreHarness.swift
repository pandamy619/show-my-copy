import Foundation

@testable import ShowMyCopy

/// The two `HistoryStore` implementations. What the protocol promises is tested once, in the contract suites, and
/// run against each.
enum StoreKind: CaseIterable, Sendable {
    case inMemory
    case persistent
}

/// Builds the history stores of the contract suites, with the blob store and the disk they share, so a new
/// dependency of a store is added here once.
///
/// A persistent store sweeps blobs that no saved record uses when it is made, as at launch: make the store before
/// writing blobs for content that is not in `restoring`.
@MainActor
final class StoreHarness {
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    let blobs: any BlobStore
    let disk = FakeHistoryPersistence()
    /// The time a store is made at: what `restoring` entries are checked against.
    var now = StoreHarness.start

    init(blobs: any BlobStore = InMemoryBlobStore()) {
        self.blobs = blobs
    }

    /// A store of `kind` that starts with `restoring`, newest first, as a history saved before. Expired passwords
    /// and what `retention` does not allow are removed first, as at launch.
    func make(
        _ kind: StoreKind,
        retention: RetentionPolicy = .default,
        restoring entries: [ClipboardEntry] = []
    ) throws -> any HistoryStore {
        switch kind {
        case .inMemory:
            return InMemoryHistoryStore(restoring: entries, at: now, retention: retention, blobs: blobs)
        case .persistent:
            let coder = StoredEntryCoder(sealer: FakeSecretSealer(), hasher: SHA256ContentHasher())
            try disk.insert(try entries.compactMap { try coder.record(for: $0) })
            return PersistentHistoryStore.loadedNow(
                persistence: disk, sealer: FakeSecretSealer(), savesPasswords: true, retention: retention, now: now,
                blobs: blobs)
        }
    }

    /// A text entry as saved before, for `restoring`.
    static func saved(
        _ text: String,
        at date: Date,
        concealed: Bool = false,
        expiresAt: Date? = nil,
        pinned: Bool = false
    ) -> ClipboardEntry {
        let content = ClipboardContent.text(text)
        return ClipboardEntry(
            content: content, contentHash: SHA256ContentHasher().hash(content), date: date, sourceApp: nil,
            isConcealed: concealed, expiresAt: expiresAt, isPinned: pinned)
    }
}
