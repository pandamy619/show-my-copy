import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct ClipboardMonitorFileThumbnailTests {
    private let pasteboard = FakePasteboard()
    private let blobs = CountingBlobStore()
    private let maker = FakeFileThumbnailMaker()
    private let history: InMemoryHistoryStore
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let finder = SourceApp(bundleIdentifier: "com.apple.finder", name: "Finder")
    private let photo = URL(filePath: "/Users/me/Pictures/IMG_0001.jpg")
    private let video = URL(filePath: "/Users/me/Movies/clip.mov")
    private let document = URL(filePath: "/Users/me/notes.txt")

    init() {
        history = InMemoryHistoryStore(blobs: blobs)
    }

    private func makeMonitor(now: Date? = nil, passwordPolicy: PasswordPolicy = .default) -> ClipboardMonitor {
        ClipboardMonitor(
            pasteboard: pasteboard,
            history: history,
            frontmostApp: { [finder] in finder },
            now: { [date] in now ?? date },
            passwordPolicy: { passwordPolicy },
            fileThumbnailIngestor: FileThumbnailIngestor(blobs: blobs, maker: maker)
        )
    }

    @Test func recordsCopiedFilesWithThumbnailsOnceTheyAreMade() async throws {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copyFiles([photo, document, video])
        monitor.poll()
        #expect(history.entries.isEmpty)
        await monitor.finishStoringImages()

        let entry = try #require(history.entries.first)
        guard case .files(let files) = entry.content else {
            Issue.record("Expected files")
            return
        }
        #expect(files.map(\.url) == [photo, document, video])
        #expect(files.map(\.thumbnail?.kind) == [.image, nil, .movie])
        #expect(entry.sourceApp == finder)
        #expect(entry.date == date)
        #expect(history.currentEntryID == entry.id)
        #expect(blobs.allIDs() == Set(entry.content.blobIDs))
    }

    @Test func nothingIsCurrentWhileThumbnailsAreMade() async {
        let monitor = makeMonitor()
        pasteboard.copy("text")
        monitor.poll()
        #expect(history.currentEntryID != nil)

        pasteboard.copyFiles([photo])
        monitor.poll()
        #expect(history.currentEntryID == nil)
        await monitor.finishStoringImages()
        #expect(history.currentEntryID == history.entries.first?.id)
    }

    @Test func nextCopyIsReadOnceTheFilesAreRecorded() async {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copyFiles([video])
        monitor.poll()
        pasteboard.copy("after the video")
        monitor.poll()
        #expect(history.entries.isEmpty)

        await monitor.finishStoringImages()
        monitor.poll()
        #expect(history.entries.map(\.kind) == [.text, .files])
        #expect(history.entries.first?.text == "after the video")
    }

    @Test func filesAndImagesKeepTheirOrder() async {
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard, history: history, frontmostApp: { nil },
            imageIngestor: ImageIngestor(blobs: blobs, thumbnails: FakeThumbnailMaker()),
            fileThumbnailIngestor: FileThumbnailIngestor(blobs: blobs, maker: maker))
        monitor.poll()
        pasteboard.copyFiles([photo])
        monitor.poll()
        await monitor.finishStoringImages()
        pasteboard.copy([.png: Data([0x89, 0x50, 0x4E, 0x47, 1])])
        monitor.poll()
        await monitor.finishStoringImages()
        pasteboard.copyFiles([video])
        monitor.poll()
        await monitor.finishStoringImages()
        #expect(history.entries.map(\.kind) == [.files, .image, .files])
    }

    @Test func sameFilesCopiedAgainAreOneEntryWithOneThumbnail() async {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copyFiles([photo])
        monitor.poll()
        await monitor.finishStoringImages()
        pasteboard.copy("between")
        monitor.poll()
        pasteboard.copyFiles([photo])
        monitor.poll()
        await monitor.finishStoringImages()

        #expect(history.entries.map(\.kind) == [.files, .text])
        #expect(blobs.allIDs() == Set(history.entries[0].content.blobIDs))
        #expect(blobs.allIDs().count == 1)
    }

    @Test func filesOnThePasteboardAtLaunchKeepTheirEntryWithoutNewThumbnails() async throws {
        let monitor = makeMonitor()
        pasteboard.copyFiles([photo])
        monitor.poll()
        await monitor.finishStoringImages()
        let entry = try #require(history.entries.first)
        history.markCurrentSkipped()
        let asked = maker.thumbnailNames.count

        // The next launch finds the same files on the pasteboard.
        let relaunched = makeMonitor(now: date + 100)
        relaunched.poll()
        await relaunched.finishStoringImages()
        #expect(history.entries == [entry])
        #expect(history.currentEntryID == entry.id)
        #expect(maker.thumbnailNames.count == asked)
        #expect(blobs.writeCount == 1)
    }

    @Test func filesAreDroppedWhenTheAppWritesWhileThumbnailsAreMade() async {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copyFiles([photo, video])
        monitor.poll()
        // An entry is copied back from the history before the thumbnails are made.
        let written = pasteboard.write("picked")
        monitor.acknowledge(changeCount: written ?? 0)
        await monitor.finishStoringImages()

        #expect(history.entries.isEmpty)
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func secretMarkedFilesGetNoThumbnails() async {
        let monitor = makeMonitor(passwordPolicy: PasswordPolicy(savesPasswords: true, lifetime: 600))
        monitor.poll()
        pasteboard.copyFiles([photo], markers: [PasteboardMarker.concealed])
        monitor.poll()
        await monitor.finishStoringImages()
        // The reader keeps a secret as concealed text, never as files.
        #expect(!history.entries.contains { $0.kind == .files })
        #expect(maker.askedNames.isEmpty)
        #expect(blobs.writeCount == 0)
    }

    @Test func withoutTheIngestorFilesAreRecordedAtOnce() {
        let monitor = ClipboardMonitor(pasteboard: pasteboard, history: history, frontmostApp: { nil })
        monitor.poll()
        pasteboard.copyFiles([photo])
        monitor.poll()
        #expect(history.entries.first?.content == .files([FileReference(url: photo, byteSize: nil)]))
    }
}
