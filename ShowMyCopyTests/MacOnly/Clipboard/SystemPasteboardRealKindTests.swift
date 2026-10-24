import AppKit
import Testing

@testable import ShowMyCopy

/// Writes and reads rich text, images and files on real `NSPasteboard`s, to check what the fakes assume. Each test
/// uses its own named pasteboard, so the user's clipboard is never touched.
@MainActor
struct SystemPasteboardRealKindTests {
    private let sourceType = NSPasteboard.PasteboardType(PasteboardMarker.source)

    private func withIsolatedPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ShowMyCopyTests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        _ = pasteboard.clearContents()
        try body(pasteboard)
    }

    private func read(_ pasteboard: NSPasteboard) -> CapturedItem {
        PasteboardSnapshotReader(
            pasteboard: SystemPasteboard(pasteboard: pasteboard, bundleIdentifier: nil),
            contentReaders: PasteboardSnapshotReader.standardReaders(readsImages: true)
        )
        .read(fromPasswordManager: false, savesPasswords: false)
    }

    @Test func richTextRoundTrips() throws {
        try withIsolatedPasteboard { backend in
            let rtf = Data(#"{\rtf1\ansi {\b Bold} text}"#.utf8)
            let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: "com.example.ShowMyCopy")
            _ = try #require(pasteboard.write(.richText(rtf: rtf, plain: "Bold text"), concealed: false))
            #expect(backend.string(forType: sourceType) == "com.example.ShowMyCopy")
            #expect(read(backend) == .content(.richText(rtf: rtf, plain: "Bold text"), isSecret: false))
        }
    }

    @Test func imageRoundTripsAsItsBytes() throws {
        try withIsolatedPasteboard { backend in
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
            let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: "com.example.ShowMyCopy")
            _ = try #require(pasteboard.write(.image(png, typeIdentifier: "public.png"), concealed: false))
            #expect(read(backend) == .image(CapturedImage(data: png, typeIdentifier: "public.png")))
        }
    }

    @Test func filesRoundTripOneItemEach() throws {
        try withIsolatedPasteboard { backend in
            let urls = [URL(filePath: "/tmp/ShowMyCopy a.txt"), URL(filePath: "/tmp/ShowMyCopy b.txt")]
            let pasteboard = SystemPasteboard(pasteboard: backend, bundleIdentifier: "com.example.ShowMyCopy")
            _ = try #require(pasteboard.write(.files(urls), concealed: false))
            #expect(pasteboard.itemCount == 2)
            #expect(pasteboard.fileURLs().map(\.path) == urls.map(\.path))
            #expect(backend.string(forType: sourceType) == "com.example.ShowMyCopy")
            guard case .content(.files(let files), isSecret: false) = read(backend) else {
                Issue.record("Written files read back as files")
                return
            }
            #expect(files.map(\.name) == ["ShowMyCopy a.txt", "ShowMyCopy b.txt"])
        }
    }

    @Test func textWithAPictureOfItReadsAsRichText() {
        withIsolatedPasteboard { backend in
            // Like Word or Excel: styled text, its plain text and a picture of it, on one item.
            let rtf = Data(#"{\rtf1 cells}"#.utf8)
            let item = NSPasteboardItem()
            item.setData(rtf, forType: .rtf)
            item.setString("cells", forType: .string)
            item.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
            #expect(backend.writeObjects([item]))
            #expect(read(backend) == .content(.richText(rtf: rtf, plain: "cells"), isSecret: false))
        }
    }
}
