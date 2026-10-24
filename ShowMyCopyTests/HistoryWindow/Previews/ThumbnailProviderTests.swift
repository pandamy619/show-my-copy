import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct ThumbnailProviderTests {
    private let blobs = ReadCountingBlobStore()
    private let decoder = FakeImageDecoder()

    private func storedImage(thumbnail: Data = Data(repeating: 8, count: 100)) throws -> ImageReference {
        try ContentFixtures.storedImage(in: blobs, thumbnail: thumbnail)
    }

    @Test func loadsTheThumbnailNotTheImage() async throws {
        let image = try storedImage()
        let provider = ThumbnailProvider(blobs: blobs, decoder: decoder)

        let thumbnail = try #require(await provider.thumbnail(for: image) as? FakePreviewImage)
        #expect(thumbnail.data == Data(repeating: 8, count: 100))
        #expect(blobs.readCount(of: image.blobID) == 0)
        #expect(decoder.requestedPixelSizes == [ThumbnailReference.maximumPixelSize])
    }

    @Test func isLoadingUntilLoadedThenCached() async throws {
        let image = try storedImage()
        let provider = ThumbnailProvider(blobs: blobs, decoder: decoder)
        #expect(provider.state(for: image).isLoading)

        _ = await provider.thumbnail(for: image)
        #expect(provider.state(for: image).value != nil)

        // A row that appears again gets the cached thumbnail without reading the blob again.
        _ = await provider.thumbnail(for: image)
        #expect(provider.loadCount == 1)
        #expect(blobs.totalReads == 1)
        #expect(decoder.decodeCount == 1)
    }

    @Test func rowsAskingAtOnceShareOneLoad() async throws {
        let image = try storedImage()
        let provider = ThumbnailProvider(blobs: blobs, decoder: decoder)
        async let first = provider.thumbnail(for: image)
        async let second = provider.thumbnail(for: image)
        let results = await [first, second]
        #expect(results.allSatisfy { $0 != nil })
        #expect(provider.loadCount == 1)
        #expect(decoder.decodeCount == 1)
    }

    @Test func imageWithoutThumbnailFailsWithoutReading() {
        let image = ContentFixtures.imageReference(thumbnailBytes: nil)
        let provider = ThumbnailProvider(blobs: blobs, decoder: decoder)
        #expect(provider.state(for: image).isFailed)
        #expect(blobs.totalReads == 0)
    }

    @Test func withoutBlobStoreOrDecoderEveryThumbnailFails() async throws {
        let image = try storedImage()
        let noBlobs = ThumbnailProvider(blobs: nil, decoder: decoder)
        let noDecoder = ThumbnailProvider(blobs: blobs, decoder: nil)
        #expect(noBlobs.state(for: image).isFailed)
        #expect(noDecoder.state(for: image).isFailed)
        #expect(await noBlobs.thumbnail(for: image) == nil)
        #expect(await noDecoder.thumbnail(for: image) == nil)
        #expect(blobs.totalReads == 0)
    }

    @Test func missingBlobFailsAndIsNotReadAgain() async {
        // The thumbnail's blob was never written, as after a deleted entry.
        let image = ContentFixtures.imageReference()
        let provider = ThumbnailProvider(blobs: blobs, decoder: decoder)
        #expect(await provider.thumbnail(for: image) == nil)
        #expect(provider.state(for: image).isFailed)

        #expect(await provider.thumbnail(for: image) == nil)
        #expect(blobs.totalReads == 1)
    }

    @Test func dataThatIsNotAnImageFails() async throws {
        let image = try storedImage(thumbnail: FakeImageDecoder.notAnImage)
        let provider = ThumbnailProvider(blobs: blobs, decoder: decoder)
        #expect(await provider.thumbnail(for: image) == nil)
        #expect(provider.state(for: image).isFailed)
    }

    @Test func cacheIsBoundedByCount() async throws {
        let images = try (0..<3).map { _ in try storedImage() }
        let limits = ThumbnailProvider.Limits(count: 2, bytes: 10_000_000, failures: 10)
        let provider = ThumbnailProvider(blobs: blobs, decoder: decoder, limits: limits)
        for image in images {
            _ = await provider.thumbnail(for: image)
        }
        // The first one was dropped; it loads again when its row appears.
        #expect(provider.state(for: images[0]).isLoading)
        #expect(provider.state(for: images[1]).value != nil)
        #expect(provider.state(for: images[2]).value != nil)
    }

    @Test func cacheIsBoundedByDecodedBytes() async throws {
        let images = try (0..<3).map { _ in try storedImage() }
        // Each fake thumbnail is 256 × 192 pixels, 196,608 bytes decoded. Room for two.
        let limits = ThumbnailProvider.Limits(count: 100, bytes: 2 * 256 * 192 * 4, failures: 10)
        let provider = ThumbnailProvider(blobs: blobs, decoder: decoder, limits: limits)
        for image in images {
            _ = await provider.thumbnail(for: image)
        }
        #expect(provider.state(for: images[0]).isLoading)
        #expect(provider.state(for: images[2]).value != nil)
    }

    @Test func decodedByteCountIsFourBytesAPixelAndNeverOverflows() {
        #expect(FakePreviewImage(data: Data(), pixelWidth: 10, pixelHeight: 20).decodedByteCount == 800)
        #expect(FakePreviewImage(data: Data(), pixelWidth: Int.max, pixelHeight: 2).decodedByteCount == Int.max)
        #expect(FakePreviewImage(data: Data(), pixelWidth: -1, pixelHeight: 20).decodedByteCount == 0)
    }
}
