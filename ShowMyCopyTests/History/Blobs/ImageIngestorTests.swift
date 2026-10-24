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
    /// Where saving an image can be held, before anything is written.
    var gate: AsyncGate?

    func inspect(
        _ data: Data, declaredType: String, maximumPixelSize: Int
    ) async throws(ThumbnailError) -> ImageInspection {
        await gate?.pass()
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

    func write(_ data: Data, as id: BlobID) throws(BlobStoreError) {
        let count = writes.withLock { count in
            count += 1
            return count
        }
        if let failingWrite, count >= failingWrite {
            throw .writeFailed
        }
        inner.write(data, as: id)
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

    /// Stores `image` through a new reservation of `blobs`, as the app does.
    private func store(
        _ image: CapturedImage,
        with ingestor: ImageIngestor,
        in blobs: InFlightBlobStore,
        known: [ContentHash: ImageReference] = [:]
    ) async throws(ImageIngestError) -> ImageReference {
        let reservation = blobs.reservation()
        return try await ingestor.ingest(image, as: reservation.newID(), known: known, reservation: reservation)
    }

    @Test func storesTheImageAndItsThumbnailUnderTheReservedID() async throws {
        let blobs = InFlightBlobStore(base: InMemoryBlobStore())
        let ingestor = ImageIngestor(thumbnails: FakeThumbnailMaker())
        let reservation = blobs.reservation()
        let blobID = reservation.newID()
        let reference = try await ingestor.ingest(captured(), as: blobID, known: [:], reservation: reservation)

        #expect(reference.blobID == blobID)
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
        // Both are held until the reservation is released, which gives them back.
        #expect(try blobs.allIDs().isEmpty)
        #expect(Set(reservation.release()) == Set(reference.blobIDs))
    }

    @Test func knownImageIsUsedAgainWithoutWriting() async throws {
        let base = CountingBlobStore()
        let ingestor = ImageIngestor(thumbnails: FakeThumbnailMaker())
        let existing = ContentFixtures.imageReference()
        let ingested = try await store(
            captured(), with: ingestor, in: InFlightBlobStore(base: base),
            known: [hasher.digest(of: data): existing])
        #expect(ingested == existing)
        #expect(base.writeCount == 0)
    }

    @Test func dataThatIsNotAnImageStoresNothing() async {
        let base = InMemoryBlobStore()
        let ingestor = ImageIngestor(thumbnails: FakeThumbnailMaker())
        await #expect(throws: ImageIngestError.notAnImage) {
            try await store(captured(Data([0, 1, 2])), with: ingestor, in: InFlightBlobStore(base: base))
        }
        #expect(base.allIDs().isEmpty)
    }

    @Test func theMakerIsToldTheTypeTheImageWasCopiedAs() async throws {
        let base = InMemoryBlobStore()
        let blobs = InFlightBlobStore(base: base)
        let ingestor = ImageIngestor(thumbnails: FakeThumbnailMaker(acceptedType: "public.tiff"))
        await #expect(throws: ImageIngestError.notAnImage) {
            try await store(captured(as: "public.png"), with: ingestor, in: blobs)
        }
        #expect(base.allIDs().isEmpty)
        let ingested = try await store(captured(as: "public.tiff"), with: ingestor, in: blobs)
        #expect(ingested.typeIdentifier == "public.tiff")
    }

    @Test func imageWithoutThumbnailIsStillStored() async throws {
        let base = InMemoryBlobStore()
        let ingestor = ImageIngestor(thumbnails: FakeThumbnailMaker(makesThumbnail: false))
        let ingested = try await store(captured(), with: ingestor, in: InFlightBlobStore(base: base))
        #expect(ingested.thumbnail == nil)
        #expect(base.allIDs() == [ingested.blobID])
    }

    @Test func failedImageWriteLeavesNothing() async {
        let base = CountingBlobStore(failingWrite: 1)
        let ingestor = ImageIngestor(thumbnails: FakeThumbnailMaker())
        await #expect(throws: ImageIngestError.storageFailed) {
            try await store(captured(), with: ingestor, in: InFlightBlobStore(base: base))
        }
        #expect(base.allIDs().isEmpty)
    }

    @Test func failedThumbnailWriteGivesTheImageBackToBeDeleted() async throws {
        let base = CountingBlobStore(failingWrite: 2)
        let blobs = InFlightBlobStore(base: base)
        let ingestor = ImageIngestor(thumbnails: FakeThumbnailMaker())
        let reservation = blobs.reservation()
        let blobID = reservation.newID()
        await #expect(throws: ImageIngestError.storageFailed) {
            try await ingestor.ingest(captured(), as: blobID, known: [:], reservation: reservation)
        }
        #expect(base.allIDs() == [blobID])
        let released = reservation.release()
        #expect(released.contains(blobID))
        try blobs.delete(released)
        #expect(base.allIDs().isEmpty)
    }
}
