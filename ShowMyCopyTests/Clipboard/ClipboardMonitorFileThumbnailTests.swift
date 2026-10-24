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
        MonitorFactory.make(
            pasteboard: pasteboard,
            history: history,
            frontmostApp: { [finder] in finder },
            now: { [date] in now ?? date },
            passwordPolicy: { passwordPolicy },
            fileThumbnailIngestor: FileThumbnailIngestor(blobs: blobs, maker: maker)
        )
    }

    @Test func recordsCopiedFilesAtOnceAndAddsTheirThumbnailsWhenMade() async throws {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copyFiles([photo, document, video])
        monitor.poll()
        let recorded = try #require(history.entries.first)
        #expect(recorded.content.blobIDs.isEmpty)
        #expect(history.currentEntryID == recorded.id)
        await monitor.finishStoringImages()

        let entry = try #require(history.entries.first)
        #expect(entry.id == recorded.id)
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

    @Test func copiesMadeWhileThumbnailsAreMadeAreNotLost() async throws {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copyFiles([video])
        monitor.poll()
        pasteboard.copy("after the video")
        monitor.poll()
        pasteboard.copyFiles([photo])
        monitor.poll()
        pasteboard.copy("last")
        monitor.poll()
        #expect(history.entries.map(\.kind) == [.text, .files, .text, .files])

        await monitor.finishStoringImages()
        // The thumbnails go to their own entries, which keep their places; the newest copy stays current.
        #expect(history.entries.map(\.kind) == [.text, .files, .text, .files])
        #expect(history.entries[1].content.blobIDs.count == 1)
        #expect(history.entries[3].content.blobIDs.count == 1)
        #expect(history.currentEntryID == history.entries.first?.id)
        #expect(maker.thumbnailNames == ["clip.mov", "IMG_0001.jpg"])
    }

    @Test func filesRemovedBeforeTheirThumbnailsAreReadyLeaveNoBlobs() async throws {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copyFiles([photo, video])
        monitor.poll()
        history.remove(id: try #require(history.entries.first).id)
        await monitor.finishStoringImages()
        #expect(history.entries.isEmpty)
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func filesAndImagesKeepTheirOrder() async {
        let monitor = MonitorFactory.make(
            pasteboard: pasteboard, history: history,
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

    @Test func entryCopiedBackWhileThumbnailsAreMadeStaysCurrent() async throws {
        let monitor = makeMonitor()
        pasteboard.copy("picked")
        monitor.poll()
        let picked = try #require(history.currentEntryID)
        pasteboard.copyFiles([photo, video])
        monitor.poll()
        // The user copies an older entry back from the history before the thumbnails are made.
        let written = pasteboard.write("picked")
        monitor.acknowledge(changeCount: written ?? 0)
        history.record(text: "picked", sourceApp: nil, at: date + 1)
        await monitor.finishStoringImages()

        #expect(history.currentEntryID == picked)
        #expect(history.entries.first?.id == picked)
        #expect(history.entries[1].content.blobIDs.count == 2)
    }

    @Test func thumbnailsAreNotMadeAgainForFilesThatHaveThem() async {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copyFiles([photo])
        monitor.poll()
        await monitor.finishStoringImages()
        pasteboard.copyFiles([photo, video])
        monitor.poll()
        await monitor.finishStoringImages()
        pasteboard.copy("between")
        monitor.poll()
        pasteboard.copyFiles([photo])
        monitor.poll()
        await monitor.finishStoringImages()
        #expect(maker.thumbnailNames == ["IMG_0001.jpg", "IMG_0001.jpg", "clip.mov"])
        #expect(blobs.allIDs() == Set(history.entries.flatMap(\.content.blobIDs)))
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
        let monitor = MonitorFactory.make(pasteboard: pasteboard, history: history)
        monitor.poll()
        pasteboard.copyFiles([photo])
        monitor.poll()
        #expect(history.entries.first?.content == .files([FileReference(url: photo, byteSize: nil)]))
    }
}
