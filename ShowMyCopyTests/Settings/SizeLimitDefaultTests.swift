import Foundation
import Testing

@testable import ShowMyCopy

/// Without a saved choice the size limit is 1 GB; a saved choice is kept.
@MainActor
struct SizeLimitDefaultTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// Runs `body` with an empty UserDefaults suite that is removed afterwards.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "ShowMyCopyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func savedValue(in defaults: UserDefaults) -> Int? {
        defaults.object(forKey: SettingsKey.historyByteLimit) as? Int
    }

    @Test func defaultIsOneGigabyteInDecimalBytes() {
        #expect(HistorySizeLimit.default == .gigabyte1)
        #expect(HistorySizeLimit.default.byteLimit == 1_000_000_000)
    }

    @Test func withNothingSavedTheLimitIsOneGigabyte() throws {
        try withDefaults { defaults in
            #expect(HistorySettings.storedSizeLimit(in: defaults) == .gigabyte1)
            #expect(HistorySettings.storedRetention(in: defaults).byteLimit == 1_000_000_000)
            // Reading the default does not save it, so a later default would apply to everyone who never chose.
            #expect(savedValue(in: defaults) == nil)
        }
    }

    @Test(arguments: [
        (0, HistorySizeLimit.noLimit), (100_000_000, .megabytes100), (500_000_000, .megabytes500),
        (1_000_000_000, .gigabyte1),
    ])
    func aSavedChoiceIsKept(saved: Int, limit: HistorySizeLimit) throws {
        try withDefaults { defaults in
            defaults.set(saved, forKey: SettingsKey.historyByteLimit)
            #expect(HistorySettings.storedSizeLimit(in: defaults) == limit)
            #expect(savedValue(in: defaults) == saved)
        }
    }

    @Test func deliberateNoLimitIsKept() throws {
        try withDefaults { defaults in
            let settings = HistorySettings(history: ClipboardHistory(), defaults: defaults, now: { Date() })
            settings.applySizeLimit(.noLimit)
            #expect(HistorySettings.storedSizeLimit(in: defaults) == .noLimit)
            #expect(HistorySettings.storedRetention(in: defaults).byteLimit == nil)
        }
    }

    /// The default is applied through the history's retention: the oldest unpinned entries go with their image
    /// files, pinned entries stay.
    @Test func defaultTrimsTheOldestEntriesThroughRetention() throws {
        try withDefaults { defaults in
            let blobs = InMemoryBlobStore()
            // Small blobs that say they are 600 MB, so two do not fit in 1 GB.
            func bigImage(_ byte: UInt8) throws -> ClipboardEntry {
                let stored = try ContentFixtures.storedImage(in: blobs, bytes: Data([byte]))
                let image = ImageReference(
                    blobID: stored.blobID, typeIdentifier: stored.typeIdentifier, pixelWidth: stored.pixelWidth,
                    pixelHeight: stored.pixelHeight, byteSize: 600_000_000, contentHash: stored.contentHash,
                    thumbnail: stored.thumbnail)
                return ClipboardEntry(
                    content: .image(image), contentHash: image.contentHash, date: start, sourceApp: nil)
            }
            var pinned = try bigImage(1)
            pinned.isPinned = true
            let oldest = try bigImage(2)
            let newest = try bigImage(3)
            let history = InMemoryHistoryStore(
                restoring: [newest, oldest, pinned], at: start, retention: RetentionPolicy(), blobs: blobs)

            HistorySettings(history: history, defaults: defaults, now: { Date() }).applyStoredLimit()

            #expect(history.entries.map(\.id) == [newest.id, pinned.id])
            #expect(blobs.allIDs().isDisjoint(with: Set(oldest.imageBlobIDs)))
            #expect(Set(newest.imageBlobIDs + pinned.imageBlobIDs).isSubset(of: blobs.allIDs()))
        }
    }
}

extension ClipboardEntry {
    fileprivate var imageBlobIDs: [BlobID] {
        if case .image(let image) = content {
            return image.blobIDs
        }
        return []
    }
}
