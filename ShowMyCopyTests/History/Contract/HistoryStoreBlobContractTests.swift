import Foundation
import Testing

@testable import ShowMyCopy

/// A blob store whose deletes fail, like a file the system will not let go of.
private final class UndeletableBlobStore: BlobStore {
    let inner = InMemoryBlobStore()

    func write(_ data: Data, as id: BlobID) { inner.write(data, as: id) }
    func read(_ id: BlobID) throws(BlobStoreError) -> Data { try inner.read(id) }
    func delete(_ ids: [BlobID]) throws(BlobStoreError) { throw .deleteFailed }
    func size(of id: BlobID) -> Int? { inner.size(of: id) }
    func totalBytes() -> Int64 { inner.totalBytes() }
    func allIDs() -> Set<BlobID> { inner.allIDs() }
}

/// Image data and thumbnails go with their entries, and count in sizes and limits, in both stores.
@MainActor
struct HistoryStoreBlobContractTests {
    private let harness = StoreHarness()
    private let start = StoreHarness.start

    private var blobs: any BlobStore {
        harness.blobs
    }

    private func storedImage(_ byte: UInt8 = 7, size: Int = 1000) throws -> ImageReference {
        try ContentFixtures.storedImage(in: blobs, bytes: Data(repeating: byte, count: size))
    }

    @Test(arguments: StoreKind.allCases)
    func removingAnImageDeletesItsBlobs(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(.image(try storedImage()), sourceApp: nil, at: start)
        store.record(text: "text", sourceApp: nil, at: start + 1)
        #expect(try blobs.allIDs().count == 2)

        store.remove(id: id)
        #expect(try blobs.allIDs().isEmpty)
        #expect(store.entries.map(\.text) == ["text"])
    }

    @Test(arguments: StoreKind.allCases)
    func imagesPushedOutByTheEntryLimitLoseTheirBlobs(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: RetentionPolicy(entryLimit: 10))
        store.record(.image(try storedImage(1)), sourceApp: nil, at: start)
        for index in 1...10 {
            store.record(text: "text \(index)", sourceApp: nil, at: start + Double(index))
        }
        #expect(store.entries.count == 10)
        #expect(try blobs.allIDs().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func byteLimitCountsTheImageDataAndThumbnail(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: RetentionPolicy(byteLimit: 2000))
        store.record(.image(try storedImage(1, size: 1000)), sourceApp: nil, at: start)
        #expect(store.stats() == HistoryStats(count: 1, totalBytes: 1100))

        // 1100 + 1100 is over the limit: the older image goes, with its blobs.
        let newer = try storedImage(2, size: 1000)
        store.record(.image(newer), sourceApp: nil, at: start + 1)
        #expect(store.entries.map(\.content) == [.image(newer)])
        #expect(try blobs.allIDs() == Set(newer.blobIDs))
    }

    @Test(arguments: StoreKind.allCases)
    func imageLargerThanTheByteLimitIsNotKept(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: RetentionPolicy(byteLimit: 500))
        store.record(.image(try storedImage()), sourceApp: nil, at: start)
        #expect(store.entries.isEmpty)
        #expect(try blobs.allIDs().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func clearDeletesEveryBlobAndCountsTheirBytes(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        store.record(.image(try storedImage(1)), sourceApp: nil, at: start)
        store.record(.image(try storedImage(2, size: 3000)), sourceApp: nil, at: start + 1)
        store.record(text: "abc", sourceApp: nil, at: start + 2)

        #expect(store.clear() == ClearResult(removedCount: 3, freedBytes: 1100 + 3100 + 3))
        #expect(try blobs.allIDs().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func sameImageCopiedAgainKeepsTheEntryAndDeletesTheNewCopy(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let first = try storedImage(5)
        let id = store.record(.image(first), sourceApp: nil, at: start)
        store.record(text: "between", sourceApp: nil, at: start + 1)

        #expect(store.record(.image(try storedImage(5)), sourceApp: nil, at: start + 2) == id)
        #expect(store.entries.first?.content == .image(first))
        #expect(try blobs.allIDs() == Set(first.blobIDs))
    }

    @Test(arguments: StoreKind.allCases)
    func recordingTheSameReferenceAgainKeepsItsBlobs(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let image = try storedImage()
        store.record(.image(image), sourceApp: nil, at: start)
        store.record(.image(image), sourceApp: nil, at: start + 1)
        #expect(try blobs.allIDs() == Set(image.blobIDs))
        #expect(store.entries.count == 1)
    }

    @Test(arguments: StoreKind.allCases)
    func imageOrFilesThatTurnOutToBeASecretAreRemovedNotConcealed(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let imageID = store.record(.image(try storedImage()), sourceApp: nil, at: start)
        let filesID = store.record(ContentFixtures.files("/a"), sourceApp: nil, at: start + 1)
        store.record(text: "kept", sourceApp: nil, at: start + 2)

        store.conceal(id: imageID, expiresAt: start + 60)
        store.conceal(id: filesID, expiresAt: start + 60)
        #expect(store.entries.map(\.text) == ["kept"])
        #expect(try blobs.allIDs().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func imageRecordedAsASecretIsNotKept(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let image = try storedImage()
        store.record(.image(image), sourceApp: nil, at: start)
        store.record(text: "other", sourceApp: nil, at: start + 1)

        let id = store.record(.image(image), sourceApp: nil, at: start + 2, concealed: true, expiresAt: start + 60)
        #expect(!store.entries.contains { $0.id == id })
        #expect(store.entries.map(\.text) == ["other"])
        #expect(store.currentEntryID == nil)
        #expect(try blobs.allIDs().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func restoringOverTheLimitDeletesTheBlobsOfWhatIsDropped(store kind: StoreKind) throws {
        let image = try storedImage()
        let hasher = SHA256ContentHasher()
        let saved =
            (0..<10).map { index in StoreHarness.saved("text \(index)", at: start - Double(index + 1)) } + [
                ClipboardEntry(
                    content: .image(image), contentHash: hasher.hash(.image(image)), date: start - 20, sourceApp: nil)
            ]
        harness.now = start + 30
        let store = try harness.make(kind, retention: RetentionPolicy(entryLimit: 10), restoring: saved)
        #expect(store.entries.count == 10)
        #expect(try blobs.allIDs().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func failedBlobDeleteStillRemovesTheEntry(store kind: StoreKind) throws {
        let undeletable = UndeletableBlobStore()
        let store = try StoreHarness(blobs: undeletable).make(kind)
        let image = try ContentFixtures.storedImage(in: undeletable)
        let id = store.record(.image(image), sourceApp: nil, at: start)
        store.remove(id: id)
        #expect(store.entries.isEmpty)
        // Left for the sweep at the next launch.
        #expect(undeletable.allIDs().count == 2)
    }

    // MARK: - Thumbnails of copied files

    @Test(arguments: StoreKind.allCases)
    func removingFilesDeletesTheirThumbnails(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let photo = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)
        let id = store.record(.files([photo, ContentFixtures.file("/b.txt")]), sourceApp: nil, at: start)
        #expect(try blobs.allIDs().count == 1)
        store.remove(id: id)
        #expect(try blobs.allIDs().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func filesPushedOutByTheLimitsLoseTheirThumbnails(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: RetentionPolicy(entryLimit: 10))
        store.record(
            .files([try ContentFixtures.fileWithThumbnail("/a.mov", kind: .movie, in: blobs)]), sourceApp: nil,
            at: start)
        for index in 1...10 {
            store.record(text: "text \(index)", sourceApp: nil, at: start + Double(index))
        }
        #expect(try blobs.allIDs().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func byteLimitCountsTheThumbnails(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: RetentionPolicy(byteLimit: 4000))
        let photo = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs, thumbnail: Data(count: 5000))
        store.record(.files([photo]), sourceApp: nil, at: start)
        // Over the limit with its thumbnail, so it is not kept.
        #expect(store.entries.isEmpty)
        #expect(try blobs.allIDs().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func statsAndClearCountTheThumbnails(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let photo = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs, thumbnail: Data(count: 5000))
        store.record(.files([photo]), sourceApp: nil, at: start)
        let byteSize = ClipboardContent.files([photo]).byteSize
        #expect(byteSize >= 5000)
        #expect(store.stats().totalBytes == byteSize)

        #expect(store.clear().freedBytes == byteSize)
        #expect(try blobs.allIDs().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func sameFilesCopiedAgainKeepTheirThumbnailAndDeleteTheNewOne(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let first = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)
        let id = store.record(.files([first]), sourceApp: nil, at: start)
        let second = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)
        #expect(store.record(.files([second]), sourceApp: nil, at: start + 1) == id)
        #expect(store.entries.map(\.content) == [.files([first])])
        #expect(try blobs.allIDs() == first.thumbnailBlobIDs)
    }

    @Test(arguments: StoreKind.allCases)
    func sameFilesCopiedAgainGetTheThumbnailsTheyLacked(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(ContentFixtures.files("/a.jpg", "/b.txt"), sourceApp: nil, at: start)
        let photo = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)
        let newer = ClipboardContent.files([photo, ContentFixtures.file("/b.txt")])
        #expect(store.record(newer, sourceApp: nil, at: start + 1) == id)
        let entry = try #require(store.entries.first)
        #expect(entry.id == id)
        #expect(entry.content == newer)
        #expect(entry.byteSize == newer.byteSize)
        #expect(entry.date == start + 1)
        #expect(try blobs.allIDs() == photo.thumbnailBlobIDs)
    }

    @Test(arguments: StoreKind.allCases)
    func filesThatTurnOutToBeASecretLoseTheirThumbnails(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let photo = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)
        store.record(.files([photo]), sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)
        #expect(store.entries.isEmpty)
        #expect(try blobs.allIDs().isEmpty)
    }

    // MARK: - File details added after the files were recorded

    @Test(arguments: StoreKind.allCases)
    func thumbnailsAreAddedWithoutMovingTheEntry(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(ContentFixtures.files("/a.jpg", "/b.txt"), sourceApp: nil, at: start)
        let textID = store.record(text: "newer", sourceApp: nil, at: start + 1)
        let revision = store.revision
        let photo = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)

        store.addFileDetails([photo, ContentFixtures.file("/b.txt")], toEntry: id)
        #expect(store.entries.map(\.id) == [textID, id])
        #expect(store.currentEntryID == textID)
        let entry = store.entries[1]
        #expect(entry.content == .files([photo, ContentFixtures.file("/b.txt")]))
        #expect(entry.date == start)
        #expect(entry.byteSize == entry.content.byteSize)
        #expect(store.revision != revision)
        #expect(try blobs.allIDs() == photo.thumbnailBlobIDs)

        store.remove(id: id)
        #expect(try blobs.allIDs().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func thumbnailsForAnEntryThatIsGoneAreDeleted(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(ContentFixtures.files("/a.jpg"), sourceApp: nil, at: start)
        store.remove(id: id)
        store.addFileDetails([try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)], toEntry: id)
        #expect(store.entries.isEmpty)
        #expect(try blobs.allIDs().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func thumbnailsTheEntryAlreadyHasAreDeleted(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let first = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)
        let id = store.record(.files([first]), sourceApp: nil, at: start)
        let revision = store.revision
        store.addFileDetails([try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)], toEntry: id)
        #expect(store.entries.map(\.content) == [.files([first])])
        #expect(store.revision == revision)
        #expect(try blobs.allIDs() == first.thumbnailBlobIDs)
    }

    @Test(arguments: StoreKind.allCases)
    func thumbnailsOfOtherFilesAreDeleted(store kind: StoreKind) throws {
        let store = try harness.make(kind)
        let id = store.record(ContentFixtures.files("/a.jpg"), sourceApp: nil, at: start)
        store.addFileDetails([try ContentFixtures.fileWithThumbnail("/other.jpg", in: blobs)], toEntry: id)
        let textID = store.record(text: "text", sourceApp: nil, at: start + 1)
        store.addFileDetails([try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)], toEntry: textID)
        #expect(store.entries.map(\.content) == [.text("text"), ContentFixtures.files("/a.jpg")])
        #expect(try blobs.allIDs().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func thumbnailsThatPassTheByteLimitTrimTheHistory(store kind: StoreKind) throws {
        let store = try harness.make(kind, retention: RetentionPolicy(byteLimit: 3000))
        let id = store.record(ContentFixtures.files("/a.jpg"), sourceApp: nil, at: start)
        store.addFileDetails(
            [try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs, thumbnail: Data(count: 4000))], toEntry: id)
        // Too large with its thumbnail: it goes, and its thumbnail with it.
        #expect(store.entries.isEmpty)
        #expect(try blobs.allIDs().isEmpty)
    }
}
