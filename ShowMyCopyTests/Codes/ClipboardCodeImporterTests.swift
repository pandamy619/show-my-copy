import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct ClipboardCodeImporterTests {
    private let pasteboard = FakePasteboard()
    private let blobs = InFlightBlobStore(base: InMemoryBlobStore())
    private let history: InMemoryHistoryStore
    private let store = CodeAccountStore(persistence: InMemoryCodeAccounts(), now: { CodeFixtures.date })
    private let preview = SourceApp(bundleIdentifier: "com.apple.Preview", name: "Preview")
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 9, 9])

    init() {
        history = InMemoryHistoryStore(blobs: blobs)
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
