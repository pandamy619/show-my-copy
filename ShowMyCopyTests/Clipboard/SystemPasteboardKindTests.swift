import AppKit
import Testing

@testable import ShowMyCopy

@MainActor
struct SystemPasteboardKindTests {
    private let backend = FakePasteboardBackend()
    private let sourceType = NSPasteboard.PasteboardType(PasteboardMarker.source)

    private func makePasteboard() -> SystemPasteboard {
        SystemPasteboard(pasteboard: backend, bundleIdentifier: "com.example.ShowMyCopy")
    }

    @Test func richTextIsWrittenAsRTFAndPlainText() throws {
        let rtf = Data(#"{\rtf1 {\b bold}}"#.utf8)
        backend.changeCount = 3
        let changeCount = try #require(makePasteboard().write(.richText(rtf: rtf, plain: "bold"), concealed: false))
        #expect(changeCount == 4)
        #expect(backend.data(forType: .rtf) == rtf)
        #expect(backend.string(forType: .string) == "bold")
        #expect(backend.preparedOptions == [.currentHostOnly])
        #expect(backend.string(forType: sourceType) == "com.example.ShowMyCopy")
    }

    @Test func imageIsWrittenAsItsOriginalBytesAndType() throws {
        let data = Data([0xFF, 0xD8, 0xFF])
        _ = try #require(makePasteboard().write(.image(data, typeIdentifier: "public.jpeg"), concealed: false))
        #expect(backend.data(forType: NSPasteboard.PasteboardType("public.jpeg")) == data)
        #expect(backend.data(forType: .png) == nil)
        #expect(backend.preparedOptions == [.currentHostOnly])
        #expect(backend.string(forType: sourceType) == "com.example.ShowMyCopy")
    }

    @Test func filesAreWrittenAsFileURLsOneItemEach() throws {
        let urls = [URL(filePath: "/Users/me/a.txt"), URL(filePath: "/Users/me/Photos", directoryHint: .isDirectory)]
        _ = try #require(makePasteboard().write(.files(urls), concealed: false))
        #expect(backend.writtenObjects.compactMap { $0 as? NSURL }.map(\.absoluteString) == urls.map(\.absoluteString))
        #expect(backend.preparedOptions == [.currentHostOnly])
        #expect(backend.string(forType: sourceType) == "com.example.ShowMyCopy")
    }

    @Test func failedDataWriteFailsTheWrite() {
        backend.failingTypes = [.rtf]
        #expect(makePasteboard().write(.richText(rtf: Data([1]), plain: "x"), concealed: false) == nil)
        backend.failingTypes = [.png]
        #expect(makePasteboard().write(.image(Data([1]), typeIdentifier: "public.png"), concealed: false) == nil)
    }

    @Test func failedFileWriteFailsTheWrite() {
        backend.writeObjectsFails = true
        #expect(makePasteboard().write(.files([URL(filePath: "/a")]), concealed: false) == nil)
    }

    @Test func textPayloadIsPlainText() {
        makePasteboard().write(.text("hello"), concealed: false)
        #expect(backend.string(forType: .string) == "hello")
    }
}
