import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct ClipboardCodeImporterTests {
    private let pasteboard = FakePasteboard()
    private let blobs = InFlightBlobStore(base: InMemoryBlobStore())
    private let history: InMemoryHistoryStore
    private let persistence = InMemoryCodeAccounts()
    private let store: CodeAccountStore
    private let preview = SourceApp(bundleIdentifier: "com.apple.Preview", name: "Preview")
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 9, 9])
    /// An export whose one account is counter-based, so nothing in it can be imported.
    private let counterOnlyExport =
        "otpauth-migration://offline?data="
        + ProtobufWriter()
        .message(1, ProtobufWriter().bytes(1, Data("12345678901234567890".utf8)).string(2, "counter").varint(6, 1))
        .data.base64EncodedString()

    init() {
        history = InMemoryHistoryStore(blobs: blobs)
        store = CodeAccountStore(persistence: persistence, now: { CodeFixtures.date })
    }

    private func makeImporter(
        payloads: [String], maximumBytes: Int? = nil
    ) -> (ClipboardCodeImporter, ClipboardMonitor) {
        let monitor = MonitorFactory.make(
            pasteboard: pasteboard, history: history, frontmostApp: { [preview] in preview }, blobs: blobs,
            imageIngestor: ImageIngestor(thumbnails: FakeThumbnailMaker()))
        monitor.poll()
        let importer = ClipboardCodeImporter(
            pasteboard: pasteboard, history: history, monitor: monitor, reader: FakeQRCodeReader(payloads: payloads),
            store: store, maximumBytes: maximumBytes ?? ImageContentReader.defaultMaximumBytes)
        return (importer, monitor)
    }

    @Test func importsTheAccountsOfTheQRCodeAndRemovesTheScreenshot() async throws {
        let (importer, monitor) = makeImporter(payloads: [CodeFixtures.exportURL])
        pasteboard.copy([.png: png])

        let outcome = await importer.importFromClipboardImage()
        await monitor.finishEnriching()

        var expected = CodeImportSummary(
            result: CodeAccountStore.AddResult(added: 1, duplicates: 0),
            outcome: CodeImport.Outcome(accounts: [], skipped: [], batchIndex: 0, batchSize: 1))
        expected.screenshotRemoved = true
        #expect(outcome == .imported(expected))
        #expect(store.accounts.map(\.displayName) == ["Example (alice@google.com)"])
        // The screenshot holds the secrets: gone from the history, the clipboard and the disk.
        #expect(history.entries.isEmpty)
        #expect(pasteboard.text == nil)
        #expect(pasteboard.clearedChangeCounts.count == 1)
        #expect(history.currentEntryID == nil)
        monitor.poll()
        #expect(history.entries.isEmpty)
    }

    @Test func anAccountInTheListAlreadyCountsAsADuplicate() async {
        await store.add([CodeFixtures.account()])
        let (importer, _) = makeImporter(payloads: [CodeFixtures.addressURL])
        pasteboard.copy([.png: png])

        guard case .imported(let summary) = await importer.importFromClipboardImage() else {
            Issue.record("Expected an import")
            return
        }
        #expect(summary.added == 0)
        #expect(summary.duplicates == 1)
        #expect(summary.screenshotRemoved)
    }

    /// The screenshot is the only copy of the secrets on this Mac until the accounts are on disk.
    @Test func theScreenshotIsKeptWhileTheAccountsCannotBeSaved() async {
        persistence.setLoadResult(.keyLockedOut)
        let (importer, monitor) = makeImporter(payloads: [CodeFixtures.addressURL])
        pasteboard.copy([.png: png])

        guard case .imported(let summary) = await importer.importFromClipboardImage() else {
            Issue.record("Expected an import")
            return
        }
        await monitor.finishEnriching()

        #expect(summary.added == 1)
        #expect(!summary.screenshotRemoved)
        #expect(summary.screenshotKeptUnsaved)
        #expect(store.accounts.count == 1)
        #expect(persistence.saveCount == 0)
        #expect(history.entries.count == 1)
        #expect(pasteboard.clearedChangeCounts.isEmpty)
    }

    @Test func theScreenshotIsKeptWhenSavingTheAccountsFails() async {
        persistence.setSaveError(.writeFailed)
        let (importer, _) = makeImporter(payloads: [CodeFixtures.addressURL])
        pasteboard.copy([.png: png])

        guard case .imported(let summary) = await importer.importFromClipboardImage() else {
            Issue.record("Expected an import")
            return
        }

        #expect(summary.added == 1)
        #expect(!summary.screenshotRemoved)
        #expect(summary.screenshotKeptUnsaved)
        #expect(store.lastSaveFailed)
        #expect(history.entries.count == 1)
        #expect(pasteboard.clearedChangeCounts.isEmpty)
    }

    @Test func theScreenshotIsKeptWhenNoAccountCouldBeImported() async {
        let (importer, _) = makeImporter(payloads: [counterOnlyExport])
        pasteboard.copy([.png: png])

        guard case .imported(let summary) = await importer.importFromClipboardImage() else {
            Issue.record("Expected an import")
            return
        }

        #expect(summary.added == 0)
        #expect(summary.skipped.map(\.name) == ["counter"])
        #expect(!summary.screenshotRemoved)
        #expect(!summary.screenshotKeptUnsaved)
        #expect(history.entries.count == 1)
        #expect(pasteboard.clearedChangeCounts.isEmpty)
    }

    @Test func theNoteSaysTheScreenshotIsGoneOnlyWhenNoCopyOfItIsLeft() async throws {
        let monitor = MonitorFactory.make(
            pasteboard: pasteboard, history: history, frontmostApp: { [preview] in preview }, blobs: blobs,
            imageIngestor: ImageIngestor(thumbnails: FakeThumbnailMaker()))
        // The image was copied and pinned before; its copy on the clipboard now is merged into the pinned entry once
        // the image is read, which the reader waits for here.
        let reader = HookedQRCodeReader(payloads: [CodeFixtures.addressURL]) { [monitor] in
            await monitor.finishEnriching()
        }
        let importer = ClipboardCodeImporter(
            pasteboard: pasteboard, history: history, monitor: monitor, reader: reader, store: store)
        pasteboard.copy([.png: png])
        monitor.poll()
        await monitor.finishEnriching()
        let pinned = try #require(history.entries.first)
        history.setPinned(true, id: pinned.id)
        pasteboard.copy("something else")
        monitor.poll()
        pasteboard.copy([.png: png])

        guard case .imported(let summary) = await importer.importFromClipboardImage() else {
            Issue.record("Expected an import")
            return
        }
        await monitor.finishEnriching()

        #expect(summary.added == 1)
        let imageIsKept = history.entries.contains { $0.contentHash == pinned.contentHash }
        #expect(summary.screenshotRemoved == !imageIsKept)
    }

    @Test func noImageOnTheClipboard() async {
        let (importer, _) = makeImporter(payloads: [CodeFixtures.addressURL])
        pasteboard.copy("text")

        #expect(await importer.importFromClipboardImage() == .noImage)
        #expect(history.entries.count == 1)
        #expect(pasteboard.text == "text")
    }

    @Test func anImageOverTheLimitIsNotRead() async {
        let (importer, _) = makeImporter(payloads: [CodeFixtures.addressURL], maximumBytes: 3)
        pasteboard.copy([.png: png])

        #expect(await importer.importFromClipboardImage() == .noImage)
    }

    @Test func anImageWithoutAQRCodeIsLeftAlone() async {
        let (importer, monitor) = makeImporter(payloads: [])
        pasteboard.copy([.png: png])

        #expect(await importer.importFromClipboardImage() == .noQRCode)
        await monitor.finishEnriching()
        #expect(history.entries.count == 1)
        #expect(pasteboard.clearedChangeCounts.isEmpty)
    }

    @Test func aQRCodeOfSomethingElseIsLeftAlone() async {
        let (importer, _) = makeImporter(payloads: ["https://example.com", "otpauth://hotp/a?secret=JBSWY3DPEHPK3PXP"])
        pasteboard.copy([.png: png])

        #expect(await importer.importFromClipboardImage() == .notAnAccount(.address(.unsupportedType("hotp"))))
        #expect(store.accounts.isEmpty)
        #expect(pasteboard.clearedChangeCounts.isEmpty)
    }

    @Test func theClipboardIsLeftAloneWhenSomethingWasCopiedWhileTheImageWasRead() async {
        let reader = HookedQRCodeReader(payloads: [CodeFixtures.addressURL]) { [pasteboard] in
            await pasteboard.copy("newer")
        }
        let monitor = MonitorFactory.make(
            pasteboard: pasteboard, history: history, frontmostApp: { [preview] in preview }, blobs: blobs,
            imageIngestor: ImageIngestor(thumbnails: FakeThumbnailMaker()))
        monitor.poll()
        let importer = ClipboardCodeImporter(
            pasteboard: pasteboard, history: history, monitor: monitor, reader: reader, store: store)
        pasteboard.copy([.png: png])

        guard case .imported(let summary) = await importer.importFromClipboardImage() else {
            Issue.record("Expected an import")
            return
        }
        #expect(summary.added == 1)
        #expect(!summary.screenshotRemoved)
        #expect(pasteboard.text == "newer")
        #expect(pasteboard.clearedChangeCounts.isEmpty)
    }
}

/// Finds the payloads after running `whileReading`, like another app copying while Vision looks at the image.
private final class HookedQRCodeReader: QRCodeReading, Sendable {
    let payloads: [String]
    let whileReading: @Sendable () async -> Void

    init(payloads: [String], whileReading: @escaping @Sendable () async -> Void) {
        self.payloads = payloads
        self.whileReading = whileReading
    }

    func payloads(inImageData data: Data, typeIdentifier: String) async -> [String] {
        await whileReading()
        return payloads
    }
}
