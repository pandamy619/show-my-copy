import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct EntryCopierKindTests {
    private let pasteboard = FakePasteboard()
    private let blobs = InMemoryBlobStore()
    private let history: InMemoryHistoryStore
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    init() {
        history = InMemoryHistoryStore(blobs: blobs)
    }

    private func makeCopier(blobs: (any BlobStore)?) -> EntryCopier {
        let monitor = ClipboardMonitor(pasteboard: pasteboard, history: history, frontmostApp: { nil })
        monitor.poll()
        return EntryCopier(
            history: history, pasteboard: pasteboard, monitor: monitor, blobs: blobs, now: { [start] in start + 10 })
    }

    private func makeCopier() -> EntryCopier {
        makeCopier(blobs: blobs)
    }

    @Test func richTextIsCopiedWithItsStyles() throws {
        let content = ContentFixtures.richText("styled")
        history.record(content, sourceApp: nil, at: start)
        history.record(text: "newer", sourceApp: nil, at: start + 1)
        let entry = try #require(history.entries.last)

        #expect(makeCopier().copy(entry))
        #expect(pasteboard.writtenPayloads == [.richText(rtf: ContentFixtures.rtf, plain: "styled")])
        #expect(history.entries.first?.id == entry.id)
        #expect(history.currentEntryID == entry.id)
    }

    @Test func imageIsCopiedAsItsOriginalData() throws {
        let image = try ContentFixtures.storedImage(in: blobs, bytes: Data([0x89, 1, 2]))
        history.record(.image(image), sourceApp: nil, at: start)
        let entry = try #require(history.entries.first)

        #expect(makeCopier().copy(entry))
        #expect(pasteboard.writtenPayloads == [.image(Data([0x89, 1, 2]), typeIdentifier: "public.png")])
        #expect(history.currentEntryID == entry.id)
        #expect(history.entries.count == 1)
    }

    @Test func filesAreCopiedAsTheirURLs() throws {
        let content = ContentFixtures.files("/Users/me/a.txt", "/Users/me/b.txt")
        history.record(content, sourceApp: nil, at: start)
        let entry = try #require(history.entries.first)

        #expect(makeCopier().copy(entry))
        #expect(
            pasteboard.writtenPayloads == [
                .files([URL(filePath: "/Users/me/a.txt"), URL(filePath: "/Users/me/b.txt")])
            ])
    }

    @Test func imageWhoseDataIsGoneIsNotCopied() throws {
        let image = try ContentFixtures.storedImage(in: blobs)
        history.record(.image(image), sourceApp: nil, at: start)
        history.record(text: "newer", sourceApp: nil, at: start + 1)
        let entry = try #require(history.entries.last)
        blobs.delete([image.blobID])
        let entriesBefore = history.entries

        #expect(!makeCopier().copy(entry))
        #expect(pasteboard.writtenPayloads.isEmpty)
        #expect(history.entries == entriesBefore)
    }

    @Test func imageIsNotCopiedWithoutTheBlobStore() throws {
        let image = try ContentFixtures.storedImage(in: blobs)
        history.record(.image(image), sourceApp: nil, at: start)
        let entry = try #require(history.entries.first)
        #expect(!makeCopier(blobs: nil).copy(entry))
        #expect(pasteboard.writtenPayloads.isEmpty)
    }

    @Test func copiedImageIsNotRecordedAgainByTheMonitor() throws {
        let image = try ContentFixtures.storedImage(in: blobs, bytes: Data([0x89, 7]))
        history.record(.image(image), sourceApp: nil, at: start)
        history.record(text: "newer", sourceApp: nil, at: start + 1)
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard, history: history, frontmostApp: { nil },
            imageIngestor: ImageIngestor(blobs: blobs, thumbnails: FakeThumbnailMaker()))
        monitor.poll()
        let entry = try #require(history.entries.last)
        let copier = EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor, blobs: blobs)

        #expect(copier.copy(entry))
        monitor.poll()
        #expect(history.entries.map(\.kind) == [.image, .text])
        #expect(blobs.allIDs().count == 2)
    }
}
