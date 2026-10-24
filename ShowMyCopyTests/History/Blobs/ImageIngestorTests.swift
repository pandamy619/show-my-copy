import Foundation
import Synchronization
import Testing

@testable import ShowMyCopy

/// Accepts data that starts with the PNG signature byte as an image of `size`, rejects anything else, and anything
/// declared as another type than `acceptedType` when one is set.
struct FakeThumbnailMaker: ThumbnailMaking {
    var pixelWidth = 640
    var pixelHeight = 480
    var makesThumbnail = true
    var acceptedType: String?

    func inspect(_ data: Data, declaredType: String, maximumPixelSize: Int) throws(ThumbnailError) -> ImageInspection {
        guard data.first == 0x89, acceptedType.map({ $0 == declaredType }) ?? true else {
            throw .notAnImage
        }
        let thumbnail = ImageInspection.Thumbnail(
            pngData: Data(repeating: 0x89, count: 100), pixelWidth: maximumPixelSize,
            pixelHeight: maximumPixelSize * pixelHeight / pixelWidth)
        return ImageInspection(
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, thumbnail: makesThumbnail ? thumbnail : nil)
    }
}

/// A blob store whose writes fail from the `failingWrite`-th write on, and that counts writes.
final class CountingBlobStore: BlobStore {
    let inner = InMemoryBlobStore()
    private let writes = Mutex(0)
    private let failingWrite: Int?

    init(failingWrite: Int? = nil) {
        self.failingWrite = failingWrite
    }

    var writeCount: Int {
        writes.withLock { $0 }
    }

    func write(_ data: Data) throws(BlobStoreError) -> BlobID {
        let count = writes.withLock { count in
            count += 1
            return count
        }
        if let failingWrite, count >= failingWrite {
            throw .writeFailed
        }
        return inner.write(data)
    }

    func read(_ id: BlobID) throws(BlobStoreError) -> Data { try inner.read(id) }
    func delete(_ ids: [BlobID]) { inner.delete(ids) }
    func size(of id: BlobID) -> Int? { inner.size(of: id) }
    func totalBytes() -> Int64 { inner.totalBytes() }
    func allIDs() -> Set<BlobID> { inner.allIDs() }
}

struct ImageIngestorTests {
    private let data = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    private let hasher = SHA256ContentHasher()

    private func captured(_ data: Data? = nil, as type: String = "public.png") -> CapturedImage {
        CapturedImage(data: data ?? self.data, typeIdentifier: type)
    }

    @Test func storesTheImageAndItsThumbnail() async throws {
        let blobs = InMemoryBlobStore()
        let ingestor = ImageIngestor(blobs: blobs, thumbnails: FakeThumbnailMaker())
        let ingested = try await ingestor.ingest(captured(), known: [:])
        let reference = ingested.reference

        #expect(ingested.isNew)
        #expect(reference.typeIdentifier == "public.png")
        #expect(reference.pixelWidth == 640)
        #expect(reference.pixelHeight == 480)
        #expect(reference.byteSize == data.count)
        #expect(reference.contentHash == hasher.digest(of: data))
        #expect(try blobs.read(reference.blobID) == data)
        let thumbnail = try #require(reference.thumbnail)
        #expect(thumbnail.pixelWidth == ThumbnailReference.maximumPixelSize)
        #expect(thumbnail.pixelHeight == 192)
        #expect(thumbnail.byteSize == 100)
        #expect(try blobs.read(thumbnail.blobID).count == 100)
        #expect(blobs.allIDs().count == 2)
    }

    @Test func knownImageIsUsedAgainWithoutWriting() throws {
        let blobs = CountingBlobStore()
        let ingestor = ImageIngestor(blobs: blobs, thumbnails: FakeThumbnailMaker())
        let existing = ContentFixtures.imageReference()
        let ingested = try ingestor.store(captured(), known: [hasher.digest(of: data): existing])
        #expect(ingested == IngestedImage(reference: existing, isNew: false))
        #expect(blobs.writeCount == 0)
    }

    @Test func dataThatIsNotAnImageStoresNothing() {
        let blobs = InMemoryBlobStore()
        let ingestor = ImageIngestor(blobs: blobs, thumbnails: FakeThumbnailMaker())
        #expect(throws: ImageIngestError.notAnImage) {
            try ingestor.store(captured(Data([0, 1, 2])), known: [:])
        }
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func theMakerIsToldTheTypeTheImageWasCopiedAs() throws {
        let blobs = InMemoryBlobStore()
        let ingestor = ImageIngestor(blobs: blobs, thumbnails: FakeThumbnailMaker(acceptedType: "public.tiff"))
        #expect(throws: ImageIngestError.notAnImage) {
            try ingestor.store(captured(as: "public.png"), known: [:])
        }
        #expect(blobs.allIDs().isEmpty)
        let ingested = try ingestor.store(captured(as: "public.tiff"), known: [:])
        #expect(ingested.reference.typeIdentifier == "public.tiff")
    }

    @Test func imageWithoutThumbnailIsStillStored() throws {
        let blobs = InMemoryBlobStore()
        let ingestor = ImageIngestor(blobs: blobs, thumbnails: FakeThumbnailMaker(makesThumbnail: false))
        let ingested = try ingestor.store(captured(), known: [:])
        #expect(ingested.reference.thumbnail == nil)
        #expect(blobs.allIDs() == [ingested.reference.blobID])
    }

    @Test func failedImageWriteLeavesNothing() {
        let blobs = CountingBlobStore(failingWrite: 1)
        let ingestor = ImageIngestor(blobs: blobs, thumbnails: FakeThumbnailMaker())
        #expect(throws: ImageIngestError.storageFailed) {
            try ingestor.store(captured(), known: [:])
        }
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func failedThumbnailWriteDeletesTheImage() {
        let blobs = CountingBlobStore(failingWrite: 2)
        let ingestor = ImageIngestor(blobs: blobs, thumbnails: FakeThumbnailMaker())
        #expect(throws: ImageIngestError.storageFailed) {
            try ingestor.store(captured(), known: [:])
        }
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func discardDeletesOnlyWhatWasWritten() throws {
        let blobs = InMemoryBlobStore()
        let ingestor = ImageIngestor(blobs: blobs, thumbnails: FakeThumbnailMaker())
        let new = try ingestor.store(captured(), known: [:])
        let reused = try ingestor.store(captured(), known: [new.reference.contentHash: new.reference])

        ingestor.discard(reused)
        #expect(blobs.allIDs().count == 2)
        ingestor.discard(new)
        #expect(blobs.allIDs().isEmpty)
    }
}
