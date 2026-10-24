import Foundation
import Testing

@testable import ShowMyCopy

extension ContentFixtures {
    /// A file with a thumbnail whose PNG data is written to `blobs`, as `FileThumbnailIngestor` stores it.
    static func fileWithThumbnail(
        _ path: String,
        kind: FileThumbnail.Kind = .image,
        in blobs: any BlobStore,
        thumbnail: Data = Data(repeating: 9, count: 200)
    ) throws -> FileReference {
        let id = try blobs.write(thumbnail)
        let reference = ThumbnailReference(blobID: id, pixelWidth: 256, pixelHeight: 144, byteSize: thumbnail.count)
        return file(path).withThumbnail(FileThumbnail(kind: kind, reference: reference))
    }

    /// A file with a thumbnail under a made-up blob ID.
    static func fileWithThumbnail(
        _ path: String,
        kind: FileThumbnail.Kind = .image,
        bytes: Int = 200,
        blobID: BlobID = BlobID()
    ) -> FileReference {
        let reference = ThumbnailReference(blobID: blobID, pixelWidth: 256, pixelHeight: 144, byteSize: bytes)
        return file(path).withThumbnail(FileThumbnail(kind: kind, reference: reference))
    }
}

extension FileReference {
    /// The thumbnail's blob, as a set to compare with a blob store's IDs.
    var thumbnailBlobIDs: Set<BlobID> {
        Set([thumbnail?.blobID].compactMap { $0 })
    }
}

struct FileThumbnailContentTests {
    private let hasher = SHA256ContentHasher()

    @Test func thumbnailsCountInTheSizeAndAreTheBlobsOfTheContent() {
        let photo = ContentFixtures.fileWithThumbnail("/p.jpg", bytes: 300)
        let video = ContentFixtures.fileWithThumbnail("/v.mov", kind: .movie, bytes: 500)
        let plain = ContentFixtures.file("/a.txt")
        let content = ClipboardContent.files([photo, plain, video])
        let without = ClipboardContent.files([photo.withThumbnail(nil), plain, video.withThumbnail(nil)])
        #expect(content.byteSize == without.byteSize + 800)
        #expect(content.blobIDs == [photo.thumbnail?.blobID, video.thumbnail?.blobID].compactMap { $0 })
        #expect(without.blobIDs.isEmpty)
    }

    @Test func thumbnailsAreNotPartOfTheFilesIdentity() {
        let with = ClipboardContent.files([ContentFixtures.fileWithThumbnail("/p.jpg")])
        let without = ContentFixtures.files("/p.jpg")
        #expect(with.canonicalBytes == without.canonicalBytes)
        #expect(hasher.hash(with) == hasher.hash(without))
    }

    @Test func droppingMissingBlobsKeepsTheFilesWithoutThoseThumbnails() throws {
        let gone = ContentFixtures.fileWithThumbnail("/gone.jpg")
        let kept = ContentFixtures.fileWithThumbnail("/kept.jpg")
        let content = ClipboardContent.files([gone, kept])
        let goneID = try #require(gone.thumbnail).blobID
        let dropped = try #require(content.droppingBlobs([goneID]))
        #expect(dropped == .files([gone.withThumbnail(nil), kept]))
        #expect(content.droppingBlobs([]) == content)
    }

    @Test func droppingAnyBlobOfAnImageLosesTheImage() throws {
        let image = ContentFixtures.imageReference()
        let thumbnail = try #require(image.thumbnail)
        #expect(ClipboardContent.image(image).droppingBlobs([thumbnail.blobID]) == nil)
        #expect(ClipboardContent.image(image).droppingBlobs([BlobID()]) == .image(image))
    }

    @Test func missingThumbnailsAreTakenFromANewerCopyFileByFile() {
        let had = ContentFixtures.fileWithThumbnail("/a.jpg")
        let lacked = ContentFixtures.file("/b.jpg")
        let newerA = ContentFixtures.fileWithThumbnail("/a.jpg")
        let newerB = ContentFixtures.fileWithThumbnail("/b.jpg")
        let filled = ClipboardContent.files([had, lacked]).addingMissingThumbnails(from: .files([newerA, newerB]))
        #expect(filled == .files([had, newerB]))
    }

    @Test func otherFilesOrKindsTakeNoThumbnails() {
        let content = ContentFixtures.files("/a.jpg")
        #expect(content.addingMissingThumbnails(from: .files([ContentFixtures.fileWithThumbnail("/b.jpg")])) == content)
        #expect(ClipboardContent.text("a").addingMissingThumbnails(from: content) == .text("a"))
    }
}

struct FileThumbnailPayloadTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let hasher = SHA256ContentHasher()
    private let coder = StoredEntryCoder(sealer: FakeSecretSealer(), hasher: SHA256ContentHasher())

    private func entry(_ content: ClipboardContent) -> ClipboardEntry {
        ClipboardEntry(content: content, contentHash: hasher.hash(content), date: date, sourceApp: nil)
    }

    @Test func filesWithoutThumbnailsKeepTheFormatOlderVersionsRead() throws {
        let content = ClipboardContent.files([FileReference(url: URL(filePath: "/a"), byteSize: 42)])
        // Saved on disk by earlier versions: changing it makes saved entries unreadable.
        var expected = Data([1, 0, 0, 0, 0, 0, 0, 0, 1])
        expected.appendLengthPrefixed(Data("file:///a".utf8))
        expected.appendLengthPrefixed(Data("a".utf8))
        expected.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0, 42])
        #expect(content.storedPayload == expected)
        let record = try #require(try coder.record(for: entry(content)))
        #expect(record.schemaVersion == 2)
        #expect(ClipboardContent(kind: .files, storedPayload: expected) == content)
    }

    @Test func filesWithThumbnailsRoundTripWithTheirBlobIDs() throws {
        let photo = ContentFixtures.fileWithThumbnail("/Users/me/Фото.heic", bytes: 12_000)
        let video = ContentFixtures.fileWithThumbnail("/Users/me/clip.mov", kind: .movie, bytes: 30_000)
        let original = entry(.files([photo, ContentFixtures.file("/Users/me/notes.txt"), video]))
        let record = try #require(try coder.record(for: original))
        #expect(record.schemaVersion == 3)
        #expect(record.payload.first == StoredPayload.filesWithThumbnailsFormatVersion)
        #expect(record.blobIDs == original.content.blobIDs.map(\.uuid))
        #expect(record.byteSize == original.byteSize)
        #expect(coder.decode(record) == .entry(original))
    }

    @Test func recordWithThumbnailsIsLeftAloneByVersionsBeforeThem() throws {
        let record = try #require(
            try coder.record(for: entry(.files([ContentFixtures.fileWithThumbnail("/a.jpg")]))))
        // Version 2 apps read up to schema 2, so they leave this record on disk instead of deleting it.
        #expect(record.schemaVersion > 2)
        #expect(coder.supports(record))
    }

    @Test func damagedThumbnailsAreUnreadable() throws {
        let content = ClipboardContent.files([ContentFixtures.fileWithThumbnail("/a.jpg")])
        let record = try #require(try coder.record(for: entry(content)))
        let payload = record.payload
        // The thumbnail flag follows the size: 1 + 8 count + (4 + 13) URL + (4 + 5) name + 1 + 8 size.
        let flagIndex = payload.startIndex + 44
        #expect(payload[flagIndex] == 1)
        var badFlag = payload
        badFlag[flagIndex] = 7
        #expect(coder.decode(record.replacingPayload(with: badFlag)) == .unreadable)
        var badKind = payload
        badKind[flagIndex + 1] = 9
        #expect(coder.decode(record.replacingPayload(with: badKind)) == .unreadable)
        #expect(coder.decode(record.replacingPayload(with: payload.dropLast())) == .unreadable)
    }

    @Test(arguments: [ClipboardContent.Kind.richText, .image])
    func formatTwoIsOnlyForFiles(kind: ClipboardContent.Kind) throws {
        let content = kind == .image ? ContentFixtures.image() : ContentFixtures.richText()
        var payload = content.storedPayload
        payload[payload.startIndex] = StoredPayload.filesWithThumbnailsFormatVersion
        #expect(ClipboardContent(kind: kind, storedPayload: payload) == nil)
    }
}

@MainActor
struct FileThumbnailHistoryStoreTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let blobs = InMemoryBlobStore()

    private func makeStore(retention: RetentionPolicy = .default) -> InMemoryHistoryStore {
        InMemoryHistoryStore(retention: retention, blobs: blobs)
    }

    @Test func removingFilesDeletesTheirThumbnails() throws {
        let store = makeStore()
        let photo = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)
        let id = store.record(.files([photo, ContentFixtures.file("/b.txt")]), sourceApp: nil, at: start)
        #expect(blobs.allIDs().count == 1)
        store.remove(id: id)
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func filesPushedOutByTheLimitsLoseTheirThumbnails() throws {
        let store = makeStore(retention: RetentionPolicy(entryLimit: 10))
        store.record(
            .files([try ContentFixtures.fileWithThumbnail("/a.mov", kind: .movie, in: blobs)]), sourceApp: nil,
            at: start)
        for index in 1...10 {
            store.record(text: "text \(index)", sourceApp: nil, at: start + Double(index))
        }
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func byteLimitAndStatsCountTheThumbnails() throws {
        let photo = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs, thumbnail: Data(count: 5000))
        let content = ClipboardContent.files([photo])
        let store = makeStore(retention: RetentionPolicy(byteLimit: 4000))
        store.record(content, sourceApp: nil, at: start)
        // Over the limit with its thumbnail, so it is not kept.
        #expect(store.entries.isEmpty)
        #expect(blobs.allIDs().isEmpty)

        let roomy = makeStore()
        let again = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs, thumbnail: Data(count: 5000))
        roomy.record(.files([again]), sourceApp: nil, at: start)
        #expect(roomy.stats().totalBytes == ClipboardContent.files([again]).byteSize)
        #expect(roomy.stats().totalBytes >= 5000)
    }

    @Test func clearDeletesTheThumbnailsAndCountsTheirBytes() throws {
        let store = makeStore()
        let photo = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs, thumbnail: Data(count: 1000))
        store.record(.files([photo]), sourceApp: nil, at: start)
        let result = store.clear()
        #expect(result.freedBytes == ClipboardContent.files([photo]).byteSize)
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func sameFilesCopiedAgainKeepTheirThumbnailAndDeleteTheNewOne() throws {
        let store = makeStore()
        let first = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)
        let id = store.record(.files([first]), sourceApp: nil, at: start)
        let second = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)
        #expect(store.record(.files([second]), sourceApp: nil, at: start + 1) == id)
        #expect(store.entries.map(\.content) == [.files([first])])
        #expect(blobs.allIDs() == first.thumbnailBlobIDs)
    }

    @Test func sameFilesCopiedAgainGetTheThumbnailsTheyLacked() throws {
        let store = makeStore()
        let id = store.record(ContentFixtures.files("/a.jpg", "/b.txt"), sourceApp: nil, at: start)
        let photo = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)
        let newer = ClipboardContent.files([photo, ContentFixtures.file("/b.txt")])
        #expect(store.record(newer, sourceApp: nil, at: start + 1) == id)
        let entry = try #require(store.entries.first)
        #expect(entry.id == id)
        #expect(entry.content == newer)
        #expect(entry.byteSize == newer.byteSize)
        #expect(entry.date == start + 1)
        #expect(blobs.allIDs() == photo.thumbnailBlobIDs)
    }

    @Test func filesThatTurnOutToBeASecretLoseTheirThumbnails() throws {
        let store = makeStore()
        let photo = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)
        store.record(.files([photo]), sourceApp: nil, at: start, concealed: true, expiresAt: start + 60)
        #expect(store.entries.isEmpty)
        #expect(blobs.allIDs().isEmpty)
    }
}

@MainActor
struct FileThumbnailPersistenceTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let disk = FakeHistoryPersistence()
    private let blobs = InMemoryBlobStore()

    private func makeStore(now: Date? = nil) -> PersistentHistoryStore {
        PersistentHistoryStore(
            persistence: disk, sealer: FakeSecretSealer(), savesPasswords: true, now: now ?? start, blobs: blobs)
    }

    @Test func thumbnailsSurviveARestart() throws {
        let store = makeStore()
        let content = ClipboardContent.files([
            try ContentFixtures.fileWithThumbnail("/a.mov", kind: .movie, in: blobs), ContentFixtures.file("/b"),
        ])
        store.record(content, sourceApp: nil, at: start)

        let restarted = makeStore(now: start + 1)
        #expect(restarted.entries.map(\.content) == [content])
        #expect(blobs.allIDs() == Set(content.blobIDs))
    }

    @Test func filesWhoseThumbnailIsGoneAreKeptWithTheirIcons() throws {
        let store = makeStore()
        let photo = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)
        let other = try ContentFixtures.fileWithThumbnail("/b.jpg", in: blobs)
        store.record(.files([photo, other]), sourceApp: nil, at: start)
        blobs.delete([try #require(photo.thumbnail).blobID])

        let restarted = makeStore(now: start + 1)
        #expect(restarted.entries.map(\.content) == [.files([photo.withThumbnail(nil), other])])
        #expect(disk.records.count == 1)
        #expect(blobs.allIDs() == other.thumbnailBlobIDs)
    }

    @Test func launchSweepKeepsFileThumbnailsAndDeletesOrphans() throws {
        let store = makeStore()
        let photo = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)
        store.record(.files([photo]), sourceApp: nil, at: start)
        // Made for a copy that was never recorded, for example because the app quit meanwhile.
        let orphan = blobs.write(Data([1, 2, 3]))

        _ = makeStore(now: start + 1)
        #expect(blobs.allIDs() == photo.thumbnailBlobIDs)
        #expect(!blobs.contains(orphan))
    }

    @Test func clearDeletesFileThumbnails() throws {
        let store = makeStore()
        store.record(.files([try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)]), sourceApp: nil, at: start)
        store.clear()
        #expect(blobs.allIDs().isEmpty)
        #expect(disk.records.isEmpty)
    }

    @Test func gainedThumbnailsAreSaved() throws {
        let store = makeStore()
        store.record(ContentFixtures.files("/a.jpg"), sourceApp: nil, at: start)
        let photo = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)
        store.record(.files([photo]), sourceApp: nil, at: start + 1)
        let record = try #require(disk.records.values.first)
        #expect(record.blobIDs == photo.thumbnailBlobIDs.map(\.uuid))
        #expect(record.schemaVersion == 3)
        #expect(makeStore(now: start + 2).entries.map(\.content) == [.files([photo])])
    }
}
