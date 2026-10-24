import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct FileThumbnailPreviewTests {
    private let blobs = ReadCountingBlobStore()
    private let decoder = FakeImageDecoder()
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func video() throws -> FileReference {
        try ContentFixtures.fileWithThumbnail(
            "/Users/me/clip.mov", kind: .movie, in: blobs, thumbnail: Data("frame".utf8))
    }

    @Test func fileThumbnailIsLoadedFromTheBlobStoreAndCached() async throws {
        let file = try video()
        let thumbnail = try #require(file.thumbnail)
        let provider = ThumbnailProvider(blobs: blobs, decoder: decoder)
        #expect(provider.state(for: thumbnail).isLoading)

        let loaded = try #require(await provider.thumbnail(for: thumbnail) as? FakePreviewImage)
        #expect(loaded.data == Data("frame".utf8))
        #expect(decoder.requestedPixelSizes == [ThumbnailReference.maximumPixelSize])
        #expect(provider.state(for: thumbnail).value != nil)
        _ = await provider.thumbnail(for: thumbnail)
        #expect(blobs.totalReads == 1)
    }

    @Test func missingFileThumbnailFailsSoTheIconStays() async throws {
        let file = try video()
        let thumbnail = try #require(file.thumbnail)
        blobs.base.delete([thumbnail.blobID])
        let provider = ThumbnailProvider(blobs: blobs, decoder: decoder)
        #expect(await provider.thumbnail(for: thumbnail) == nil)
        #expect(provider.state(for: thumbnail).isFailed)
    }

    @Test func withoutDecoderFileThumbnailsFail() throws {
        let thumbnail = try #require(try video().thumbnail)
        #expect(ThumbnailProvider(blobs: blobs, decoder: nil).state(for: thumbnail).isFailed)
    }

    @Test func previewListsFilesWithTheirThumbnails() throws {
        let file = try video()
        let content = ClipboardContent.files([file, ContentFixtures.file("/Users/me/notes.txt")])
        let entry = ClipboardEntry(
            content: content, contentHash: SHA256ContentHasher().hash(content), date: date, sourceApp: nil)
        let model = EntryPreviewModel(services: PreviewServices(blobs: blobs, images: decoder))
        model.open(entry)
        guard case .files(let items) = try #require(model.content) else {
            Issue.record("expected files")
            return
        }
        #expect(items.map(\.thumbnail) == [file.thumbnail, nil])
        model.close()
    }
}
