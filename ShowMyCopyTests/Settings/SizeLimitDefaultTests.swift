import Foundation
import Testing

@testable import ShowMyCopy

/// New installs get a 1 GB size limit; installs from before the default changed keep what they had.
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

    @Test func newInstallSavesOneGigabyte() throws {
        try withDefaults { defaults in
            HistorySettings.settleSizeLimitDefault(in: defaults, isNewInstall: true)
            #expect(savedValue(in: defaults) == 1_000_000_000)
            #expect(HistorySettings.storedRetention(in: defaults).byteLimit == 1_000_000_000)
        }
    }

    /// An install from before the default changed has never had a size limit. Its history may be larger than 1 GB,
    /// and removing images at launch, without being asked, would surprise. It keeps No limit, saved, so it is
    /// a choice the user can see and change in Settings.
    @Test func existingInstallThatNeverChoseKeepsNoLimit() throws {
        try withDefaults { defaults in
            HistorySettings.settleSizeLimitDefault(in: defaults, isNewInstall: false)
            #expect(savedValue(in: defaults) == 0)
            #expect(HistorySettings.storedSizeLimit(in: defaults) == .noLimit)
            #expect(HistorySettings.storedRetention(in: defaults).byteLimit == nil)
        }
    }

    /// The first launch saves the default, so later launches, no longer new, do not turn it into No limit.
    @Test func laterLaunchesOfANewInstallKeepOneGigabyte() throws {
        try withDefaults { defaults in
            HistorySettings.settleSizeLimitDefault(in: defaults, isNewInstall: true)
            HistorySettings.settleSizeLimitDefault(in: defaults, isNewInstall: false)
            #expect(savedValue(in: defaults) == 1_000_000_000)
        }
    }

    @Test(arguments: [0, 100_000_000, 300_000_000, 500_000_000, 1_000_000_000, 5_000_000_000])
    func savedChoiceIsKeptExactly(saved: Int) throws {
        for isNewInstall in [true, false] {
            try withDefaults { defaults in
                defaults.set(saved, forKey: SettingsKey.historyByteLimit)
                HistorySettings.settleSizeLimitDefault(in: defaults, isNewInstall: isNewInstall)
                #expect(savedValue(in: defaults) == saved)
            }
        }
    }

    @Test func deliberateNoLimitSurvivesASettle() throws {
        try withDefaults { defaults in
            let settings = HistorySettings(history: ClipboardHistory(), defaults: defaults)
            settings.applySizeLimit(.noLimit)
            HistorySettings.settleSizeLimitDefault(in: defaults, isNewInstall: true)
            #expect(HistorySettings.storedSizeLimit(in: defaults) == .noLimit)
        }
    }

    /// The default is applied through the history's retention: the oldest unpinned entries go with their image
    /// files, pinned entries stay.
    @Test func defaultTrimsTheOldestEntriesThroughRetention() throws {
        try withDefaults { defaults in
            HistorySettings.settleSizeLimitDefault(in: defaults, isNewInstall: true)
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

            HistorySettings(history: history, defaults: defaults).applyStoredLimit()

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
