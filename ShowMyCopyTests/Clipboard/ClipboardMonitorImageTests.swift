import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct ClipboardMonitorImageTests {
    private let pasteboard = FakePasteboard()
    private let blobs = CountingBlobStore()
    private let history: InMemoryHistoryStore
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let preview = SourceApp(bundleIdentifier: "com.apple.Preview", name: "Preview")
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 9, 9])

    init() {
        history = InMemoryHistoryStore(blobs: blobs)
    }

    private func makeMonitor() -> ClipboardMonitor {
        MonitorFactory.make(
            pasteboard: pasteboard,
            history: history,
            frontmostApp: { [preview] in preview },
            now: { [date] in date },
            imageIngestor: ImageIngestor(blobs: blobs, thumbnails: FakeThumbnailMaker())
        )
    }

    @Test func recordsACopiedImageOnceItIsStored() async throws {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copy([.png: png])
        monitor.poll()
        await monitor.finishStoringImages()

        let entry = try #require(history.entries.first)
        let image = try #require(entry.content.image)
        #expect(try blobs.read(image.blobID) == png)
        #expect(image.typeIdentifier == "public.png")
        #expect(entry.sourceApp == preview)
        #expect(entry.date == date)
        #expect(history.currentEntryID == entry.id)
        #expect(blobs.allIDs().count == 2)
    }

    @Test func nothingIsCurrentWhileTheImageIsStored() async {
        let monitor = makeMonitor()
        pasteboard.copy("text")
        monitor.poll()
        #expect(history.currentEntryID != nil)

        pasteboard.copy([.png: png])
        monitor.poll()
        #expect(history.currentEntryID == nil)
        await monitor.finishStoringImages()
        #expect(history.currentEntryID == history.entries.first?.id)
    }

    @Test func nextCopyIsReadOnceTheImageIsRecorded() async {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copy([.png: png])
        monitor.poll()
        pasteboard.copy("after the image")
        monitor.poll()
        #expect(history.entries.isEmpty)

        await monitor.finishStoringImages()
        monitor.poll()
        #expect(history.entries.map(\.kind) == [.text, .image])
        #expect(history.entries.first?.text == "after the image")
    }

    @Test func sameImageCopiedAgainIsOneEntryWithoutNewFiles() async {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copy([.png: png])
        monitor.poll()
        await monitor.finishStoringImages()
        pasteboard.copy("between")
        monitor.poll()
        pasteboard.copy([.png: png])
        monitor.poll()
        await monitor.finishStoringImages()

        #expect(history.entries.map(\.kind) == [.image, .text])
        #expect(blobs.writeCount == 2)
        #expect(blobs.allIDs().count == 2)
    }

    @Test func dataThatIsNotAnImageIsSkipped() async {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copy([.png: Data([0, 1, 2])])
        monitor.poll()
        await monitor.finishStoringImages()
        #expect(history.entries.isEmpty)
        #expect(history.currentEntryID == nil)
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func imageThatCannotBeWrittenIsSkipped() async {
        let failing = CountingBlobStore(failingWrite: 1)
        let monitor = MonitorFactory.make(
            pasteboard: pasteboard, history: history,
            imageIngestor: ImageIngestor(blobs: failing, thumbnails: FakeThumbnailMaker()))
        monitor.poll()
        pasteboard.copy([.png: png])
        monitor.poll()
        await monitor.finishStoringImages()
        #expect(history.entries.isEmpty)
    }

    @Test func imageOnThePasteboardAtLaunchKeepsItsEntry() async throws {
        let monitor = makeMonitor()
        pasteboard.copy([.png: png])
        monitor.poll()
        await monitor.finishStoringImages()
        let entry = try #require(history.entries.first)
        history.markCurrentSkipped()

        // The next launch finds the same image on the pasteboard.
        let relaunched = MonitorFactory.make(
            pasteboard: pasteboard, history: history, now: { [date] in date + 100 },
            imageIngestor: ImageIngestor(blobs: blobs, thumbnails: FakeThumbnailMaker()))
        relaunched.poll()
        await relaunched.finishStoringImages()
        #expect(history.entries == [entry])
        #expect(history.currentEntryID == entry.id)
        #expect(blobs.writeCount == 2)
    }

    @Test func imageIsDroppedWhenTheAppWritesWhileItIsStored() async {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copy([.png: png])
        monitor.poll()
        // An entry is copied back from the history before the image is stored.
        let written = pasteboard.write("picked")
        monitor.acknowledge(changeCount: written ?? 0)
        await monitor.finishStoringImages()

        #expect(history.entries.isEmpty)
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func secretMarkedImageIsNeverStored() async {
        let monitor = MonitorFactory.make(
            pasteboard: pasteboard, history: history,
            passwordPolicy: { PasswordPolicy(savesPasswords: true, lifetime: 600) },
            imageIngestor: ImageIngestor(blobs: blobs, thumbnails: FakeThumbnailMaker()))
        monitor.poll()
        pasteboard.copy([.png: png], markers: [PasteboardMarker.concealed])
        monitor.poll()
        await monitor.finishStoringImages()
        #expect(history.entries.isEmpty)
        #expect(blobs.writeCount == 0)
    }
}
