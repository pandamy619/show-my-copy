import AppKit
import Testing

@testable import ShowMyCopy

@MainActor
struct PasteboardSnapshotReaderTests {
    private let pasteboard = FakePasteboard()

    private func read(
        limit: Int = TextContentReader.defaultMaximumBytes,
        fromPasswordManager: Bool = false,
        savesPasswords: Bool = false
    ) -> CapturedItem {
        PasteboardSnapshotReader(pasteboard: pasteboard, contentReaders: [TextContentReader(maximumBytes: limit)])
            .read(fromPasswordManager: fromPasswordManager, savesPasswords: savesPasswords)
    }

    @Test func readsPlainText() {
        pasteboard.copy("hello")
        #expect(read() == .content(.text("hello"), isSecret: false))
    }

    @Test func tooLargeTextIsSkippedWithoutMakingAString() {
        pasteboard.copy(String(repeating: "a", count: ClipboardMonitor.maximumTextBytes + 1))
        #expect(read() == .skipped(.tooLarge))
        #expect(pasteboard.stringCallCount == 0)
    }

    @Test func textOfExactlyTheLimitIsRead() {
        let text = String(repeating: "a", count: ClipboardMonitor.maximumTextBytes)
        pasteboard.copy(text)
        #expect(read() == .content(.text(text), isSecret: false))
    }

    @Test func limitCountsUTF8BytesNotCharacters() {
        // "é" takes two bytes in UTF-8.
        pasteboard.copy("éééé")
        #expect(read(limit: 8) == .content(.text("éééé"), isSecret: false))
        #expect(read(limit: 7) == .skipped(.tooLarge))
        #expect(pasteboard.stringCallCount == 0)
    }

    @Test func dataThatIsNotUTF8FallsBackToTheConvertedString() {
        pasteboard.copy([.string: Data([0xFF, 0xFE, 0x41])])
        pasteboard.convertedString = "converted"
        #expect(read() == .content(.text("converted"), isSecret: false))
        #expect(pasteboard.stringCallCount == 1)
    }

    @Test func missingDataFallsBackToTheString() {
        pasteboard.copy("converted")
        pasteboard.contents = [:]
        pasteboard.convertedString = "converted"
        #expect(read() == .content(.text("converted"), isSecret: false))
    }

    @Test func fallbackStringIsCheckedAgainstTheLimit() {
        pasteboard.copy("unused")
        pasteboard.contents = [:]
        pasteboard.convertedString = "123456789"
        #expect(read(limit: 8) == .skipped(.tooLarge))
    }

    @Test(arguments: PasteboardMarker.secret.sorted())
    func secretMarkerIsCheckedBeforeAnyDataIsRead(marker: String) {
        pasteboard.copy("hunter2", markers: [marker])
        #expect(read() == .skipped(.secret))
        #expect(pasteboard.dataReadCount == 0)
        #expect(pasteboard.stringCallCount == 0)
    }

    @Test func copyFromAPasswordManagerIsNotReadWhenPasswordsAreNotSaved() {
        pasteboard.copy("hunter2")
        #expect(read(fromPasswordManager: true) == .skipped(.secret))
        #expect(pasteboard.dataReadCount == 0)
        #expect(pasteboard.stringCallCount == 0)
    }

    @Test(arguments: PasteboardMarker.alwaysSkipped.sorted())
    func alwaysSkippedMarkerIsCheckedBeforeAnyDataIsRead(marker: String) {
        pasteboard.copy("generated", markers: [marker])
        #expect(read(savesPasswords: true) == .skipped(.marked))
        #expect(pasteboard.dataReadCount == 0)
        #expect(pasteboard.stringCallCount == 0)
    }

    @Test func secretIsReadWhenPasswordsAreSaved() {
        pasteboard.copy("hunter2", markers: [PasteboardMarker.concealed])
        #expect(read(savesPasswords: true) == .content(.text("hunter2"), isSecret: true))
    }

    @Test func markerAddedWhileTheTextIsReadSkipsTheItem() {
        pasteboard.copy("hunter2")
        pasteboard.whileReadingString = { $0.addMarker(PasteboardMarker.concealed) }
        #expect(read() == .skipped(.secret))
    }

    @Test func emptiedPasteboardIsCleared() {
        pasteboard.clear()
        #expect(read() == .cleared)

        pasteboard.copy("")
        #expect(read() == .cleared)
    }

    @Test func imageIsSkipped() {
        pasteboard.copyImage()
        #expect(read() == .skipped(.unsupported))
    }

    @Test func firstReaderThatFindsContentWins() {
        pasteboard.copy([.string: Data("plain".utf8), .png: Data([0x89])])
        let reader = PasteboardSnapshotReader(
            pasteboard: pasteboard,
            contentReaders: [StubContentReader(result: .nothing), StubContentReader(result: .content(.text("stub")))]
        )
        let item = reader.read(fromPasswordManager: false, savesPasswords: false)
        #expect(item == .content(.text("stub"), isSecret: false))
        #expect(pasteboard.dataReadCount == 0)
    }
}

/// A content reader for another kind of content, as later versions add for images or files.
private struct StubContentReader: PasteboardContentReader {
    let result: ContentReading

    func read(from pasteboard: any PasteboardReading) -> ContentReading {
        result
    }
}
