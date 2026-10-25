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
        let filled = ClipboardContent.files([had, lacked]).addingMissingFileDetails(from: .files([newerA, newerB]))
        #expect(filled == .files([had, newerB]))
    }

    @Test func sizesReadLaterAreTakenAndKnownOnesStay() {
        let content = ClipboardContent.files([
            ContentFixtures.file("/a.txt", byteSize: nil), ContentFixtures.file("/b.txt", byteSize: 7),
        ])
        let read = ClipboardContent.files([
            ContentFixtures.file("/a.txt", byteSize: 100), ContentFixtures.file("/b.txt", byteSize: 200),
        ])
        guard case .files(let files) = content.addingMissingFileDetails(from: read) else {
            Issue.record("Expected files")
            return
        }
        #expect(files.map(\.byteSize) == [100, 7])
    }

    @Test func otherFilesOrKindsTakeNoThumbnails() {
        let content = ContentFixtures.files("/a.jpg")
        #expect(
            content.addingMissingFileDetails(from: .files([ContentFixtures.fileWithThumbnail("/b.jpg")])) == content)
        #expect(ClipboardContent.text("a").addingMissingFileDetails(from: content) == .text("a"))
    }
}

struct FileThumbnailPayloadTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let hasher = SHA256ContentHasher()
    private let coder = StoredEntryCoder(sealer: FakeSecretSealer(), hasher: SHA256ContentHasher())

    private func entry(_ content: ClipboardContent) -> ClipboardEntry {
        ClipboardEntry(content: content, contentHash: hasher.hash(content), date: date, sourceApp: nil)
    }

    @Test func fileWithoutThumbnailEndsWithAnEmptyThumbnailFlag() throws {
        let content = ClipboardContent.files([FileReference(url: URL(filePath: "/a"), byteSize: 42)])
        // Saved on disk: changing it makes saved entries unreadable.
        var expected = Data([1, 0, 0, 0, 0, 0, 0, 0, 1])
        expected.appendLengthPrefixed(Data("file:///a".utf8))
        expected.appendLengthPrefixed(Data("a".utf8))
        expected.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0, 42, 0])
        #expect(content.storedPayload == expected)
        #expect(ClipboardContent(kind: .files, storedPayload: expected) == content)
    }

    @Test func filesWithThumbnailsRoundTripWithTheirBlobIDs() throws {
        let photo = ContentFixtures.fileWithThumbnail("/Users/me/Фото.heic", bytes: 12_000)
        let video = ContentFixtures.fileWithThumbnail("/Users/me/clip.mov", kind: .movie, bytes: 30_000)
        let original = entry(.files([photo, ContentFixtures.file("/Users/me/notes.txt"), video]))
        let record = try #require(try coder.record(for: original))
        #expect(record.payload.first == StoredPayload.format)
        #expect(record.blobIDs == original.content.blobIDs.map(\.uuid))
        #expect(record.byteSize == original.byteSize)
        #expect(coder.decode(record) == .entry(original))
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
}

@MainActor
struct FileThumbnailPersistenceTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let disk = FakeHistoryPersistence()
    private let blobs = InMemoryBlobStore()

    private func makeStore(now: Date? = nil) -> PersistentHistoryStore {
        PersistentHistoryStore.loadedNow(
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
        let orphan = try blobs.write(Data([1, 2, 3]))

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
        #expect(makeStore(now: start + 2).entries.map(\.content) == [.files([photo])])
    }

    @Test func addedThumbnailsAreSaved() throws {
        let store = makeStore()
        let id = store.record(ContentFixtures.files("/a.jpg"), sourceApp: nil, at: start)
        let photo = try ContentFixtures.fileWithThumbnail("/a.jpg", in: blobs)
        store.addFileDetails([photo], toEntry: id)
        let record = try #require(disk.records.values.first)
        #expect(record.blobIDs == photo.thumbnailBlobIDs.map(\.uuid))
        #expect(makeStore(now: start + 1).entries.map(\.content) == [.files([photo])])
    }
}
