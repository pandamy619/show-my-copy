import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct ClipboardMonitorImageTests {
    private let pasteboard = FakePasteboard()
    private let blobs = CountingBlobStore()
    private let inFlight: InFlightBlobStore
    private let history: InMemoryHistoryStore
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let preview = SourceApp(bundleIdentifier: "com.apple.Preview", name: "Preview")
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 9, 9])
    /// Stops saving an image before it starts, when armed.
    private let gate = BlockingGate()

    init() {
        inFlight = InFlightBlobStore(base: blobs)
        history = InMemoryHistoryStore(blobs: inFlight)
    }

    private func makeMonitor(
        now: Date? = nil, policy: PasswordPolicy = .default, blobs: InFlightBlobStore? = nil
    ) -> ClipboardMonitor {
        MonitorFactory.make(
            pasteboard: pasteboard,
            history: history,
            frontmostApp: { [preview] in preview },
            now: { [date] in now ?? date },
            passwordPolicy: { policy },
            blobs: blobs ?? inFlight,
            imageIngestor: ImageIngestor(thumbnails: FakeThumbnailMaker(), hasher: GatedHasher(gate: gate))
        )
    }

    /// Every blob an entry names is stored, and every stored blob belongs to an entry.
    private func expectEveryBlobBelongsToAnEntry() {
        let used = Set(history.entries.flatMap(\.content.blobIDs))
        #expect(used.allSatisfy { blobs.contains($0) })
        #expect(blobs.allIDs() == used)
    }

    @Test func recordsACopiedImageAtOnceAndFillsItInWhenItIsSaved() async throws {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copy([.png: png])
        monitor.poll()

        let recorded = try #require(history.entries.first)
        let unsaved = try #require(recorded.content.image)
        #expect(!unsaved.isSaved)
        #expect(unsaved.thumbnail == nil)
        #expect(unsaved.typeIdentifier == "public.png")
        #expect(recorded.previewText == "PNG")
        #expect(recorded.sourceApp == preview)
        #expect(recorded.date == date)
        #expect(history.currentEntryID == recorded.id)

        await monitor.finishStoringImages()
        let entry = try #require(history.entries.first)
        let image = try #require(entry.content.image)
        #expect(entry.id == recorded.id)
        #expect(image.isSaved)
        #expect(try blobs.read(image.blobID) == png)
        #expect(image.thumbnail != nil)
        #expect(entry.previewText == "PNG 640 × 480")
        #expect(entry.contentHash == SHA256ContentHasher().hash(.image(image)))
        #expect(entry.sourceApp == preview)
        #expect(entry.date == date)
        #expect(history.currentEntryID == entry.id)
        #expect(blobs.allIDs().count == 2)
    }

    @Test func copiesMadeWhileAnImageIsSavedAreRecordedAtOnce() async {
        let monitor = makeMonitor()
        monitor.poll()
        gate.arm()
        pasteboard.copy([.png: png])
        monitor.poll()
        await gate.waitUntilReached()
        pasteboard.copy("after the image")
        monitor.poll()
        #expect(history.entries.map(\.kind) == [.text, .image])
        #expect(history.currentEntryID == history.entries.first?.id)

        gate.open()
        await monitor.finishStoringImages()
        #expect(history.entries.map(\.kind) == [.text, .image])
        #expect(history.entries.first?.text == "after the image")
        #expect(history.currentEntryID == history.entries.first?.id)
        #expect(history.entries.last?.content.image?.isSaved == true)
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
        #expect(history.currentEntryID == history.entries.first?.id)
        #expect(blobs.writeCount == 2)
        expectEveryBlobBelongsToAnEntry()
    }

    @Test func sameImageCopiedTwiceBeforeItIsSavedIsOneEntry() async {
        let monitor = makeMonitor()
        monitor.poll()
        gate.arm()
        pasteboard.copy([.png: png])
        monitor.poll()
        await gate.waitUntilReached()
        pasteboard.copy("between")
        monitor.poll()
        pasteboard.copy([.png: png])
        monitor.poll()
        #expect(history.entries.map(\.kind) == [.image, .text, .image])

        gate.open()
        await monitor.finishStoringImages()
        #expect(history.entries.map(\.kind) == [.image, .text])
        #expect(history.currentEntryID == history.entries.first?.id)
        expectEveryBlobBelongsToAnEntry()
    }

    @Test func dataThatIsNotAnImageLeavesNoEntry() async {
        let monitor = makeMonitor()
        monitor.poll()
        pasteboard.copy([.png: Data([0, 1, 2])])
        monitor.poll()
        await monitor.finishStoringImages()
        #expect(history.entries.isEmpty)
        #expect(history.currentEntryID == nil)
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func imageThatCannotBeWrittenLeavesNoEntry() async {
        let failing = CountingBlobStore(failingWrite: 1)
        let monitor = makeMonitor(blobs: InFlightBlobStore(base: failing))
        monitor.poll()
        pasteboard.copy([.png: png])
        monitor.poll()
        await monitor.finishStoringImages()
        #expect(history.entries.isEmpty)
        #expect(failing.allIDs().isEmpty)
    }

    @Test func imageOnThePasteboardAtLaunchKeepsItsEntry() async throws {
        let monitor = makeMonitor()
        pasteboard.copy([.png: png])
        monitor.poll()
        await monitor.finishStoringImages()
        let entry = try #require(history.entries.first)
        history.markCurrentSkipped()

        // The next launch finds the same image on the pasteboard.
        let relaunched = makeMonitor(now: date + 100)
        relaunched.poll()
        await relaunched.finishStoringImages()
        #expect(history.entries == [entry])
        #expect(history.currentEntryID == entry.id)
        #expect(blobs.writeCount == 2)
    }

    @Test func imageIsKeptWhenTheAppWritesWhileItIsSaved() async throws {
        let monitor = makeMonitor()
        pasteboard.copy("picked")
        monitor.poll()
        let picked = try #require(history.currentEntryID)
        gate.arm()
        pasteboard.copy([.png: png])
        monitor.poll()
        await gate.waitUntilReached()
        // An entry is copied back from the history before the image is saved.
        let written = pasteboard.write("picked")
        monitor.acknowledge(changeCount: written ?? 0)
        history.record(text: "picked", sourceApp: nil, at: date + 1)
        gate.open()
        await monitor.finishStoringImages()

        #expect(history.entries.map(\.kind) == [.text, .image])
        #expect(history.currentEntryID == picked)
        #expect(history.entries.last?.content.image?.isSaved == true)
        expectEveryBlobBelongsToAnEntry()
    }

    @Test func copyingAnEntryBackWhileAnImageIsSavedLosesNoCopy() async throws {
        history.record(text: "older", sourceApp: nil, at: date - 100)
        let monitor = makeMonitor()
        monitor.poll()
        gate.arm()
        pasteboard.copy([.png: png])
        monitor.poll()
        await gate.waitUntilReached()
        pasteboard.copy("copied while the image is saved")
        monitor.poll()

        let older = try #require(history.entries.last)
        let copier = EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor, blobs: inFlight)
        #expect(copier.copy(older))
        gate.open()
        await monitor.finishStoringImages()

        #expect(history.entries.map(\.text) == ["older", "copied while the image is saved", nil])
        let image = try #require(history.entries.last?.content.image)
        #expect(try blobs.read(image.blobID) == png)
        #expect(history.currentEntryID == older.id)
        expectEveryBlobBelongsToAnEntry()
    }

    @Test func imageCopiedBackBeforeItIsSavedIsWrittenFromTheCopiedBytes() async throws {
        let monitor = makeMonitor()
        monitor.poll()
        gate.arm()
        pasteboard.copy([.png: png])
        monitor.poll()
        await gate.waitUntilReached()
        pasteboard.copy("newer")
        monitor.poll()

        let unsaved = try #require(history.entries.last)
        let copier = EntryCopier(history: history, pasteboard: pasteboard, monitor: monitor, blobs: inFlight)
        #expect(copier.copy(unsaved))
        #expect(pasteboard.writtenPayloads == [.image(png, typeIdentifier: "public.png")])
        #expect(history.entries.first?.id == unsaved.id)
        #expect(history.currentEntryID == unsaved.id)

        gate.open()
        await monitor.finishStoringImages()
        let entry = try #require(history.entries.first)
        #expect(entry.id == unsaved.id)
        #expect(entry.content.image?.isSaved == true)
        #expect(history.currentEntryID == entry.id)
        // The monitor does not record the app's own write again.
        monitor.poll()
        #expect(history.entries.map(\.kind) == [.image, .text])
        expectEveryBlobBelongsToAnEntry()
    }

    @Test func imageRemovedBeforeItIsSavedLeavesNoBlobs() async throws {
        let monitor = makeMonitor()
        monitor.poll()
        gate.arm()
        pasteboard.copy([.png: png])
        monitor.poll()
        await gate.waitUntilReached()
        history.remove(id: try #require(history.entries.first).id)

        gate.open()
        await monitor.finishStoringImages()
        #expect(history.entries.isEmpty)
        #expect(blobs.allIDs().isEmpty)
    }

    @Test func secretMarkedImageIsNeverStored() async {
        let monitor = makeMonitor(policy: PasswordPolicy(savesPasswords: true, lifetime: 600))
        monitor.poll()
        pasteboard.copy([.png: png], markers: [PasteboardMarker.concealed])
        monitor.poll()
        await monitor.finishStoringImages()
        #expect(history.entries.isEmpty)
        #expect(blobs.writeCount == 0)
    }
}
