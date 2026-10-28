import AppKit
import Testing

@testable import ShowMyCopy

@MainActor
struct FileURLContentReaderTests {
    private let pasteboard = FakePasteboard()
    private let report = URL(filePath: "/Users/me/Отчёт.pdf")
    private let photos = URL(filePath: "/Users/me/Photos", directoryHint: .isDirectory)

    private func reader(maximumCount: Int = FileURLContentReader.defaultMaximumCount) -> FileURLContentReader {
        FileURLContentReader(maximumCount: maximumCount)
    }

    /// Sizes are read later, off the main actor (`FileSizeReader`): reading the pasteboard touches no file.
    @Test func readsTheFilesWithNamesButNoSizes() {
        pasteboard.copyFiles([report, photos])
        #expect(
            reader().read(from: pasteboard)
                == .content(
                    .files([
                        FileReference(url: report, name: "Отчёт.pdf", byteSize: nil),
                        FileReference(url: photos, name: "Photos", byteSize: nil),
                    ])))
    }

    @Test func itemWithoutFileURLsIsNotForIt() {
        pasteboard.copy("text")
        #expect(reader().read(from: pasteboard) == .nothing)
        #expect(pasteboard.fileURLReadCount == 0)
    }

    @Test func tooManyFilesAreSkippedWithoutReadingThem() {
        pasteboard.copyFiles((0..<4).map { URL(filePath: "/tmp/\($0)") })
        #expect(reader(maximumCount: 3).read(from: pasteboard) == .tooLarge(limit: 3))
        #expect(pasteboard.fileURLReadCount == 0)

        pasteboard.copyFiles((0..<3).map { URL(filePath: "/tmp/\($0)") })
        guard case .content(.files(let files)) = reader(maximumCount: 3).read(from: pasteboard) else {
            Issue.record("Three files are within the limit")
            return
        }
        #expect(files.count == 3)
    }

    @Test func defaultLimitIsAHundredFiles() {
        #expect(FileURLContentReader.defaultMaximumCount == 100)
    }

    @Test func urlsThatAreNotFilesAreLeftOut() {
        pasteboard.copyFiles([URL(string: "https://example.com/a") ?? report, report])
        guard case .content(.files(let files)) = reader().read(from: pasteboard) else {
            Issue.record("The file URL is read")
            return
        }
        #expect(files.map(\.url) == [report])
    }

    @Test func fileURLTypeWithoutURLsIsNothing() {
        pasteboard.copyFiles([])
        #expect(reader().read(from: pasteboard) == .nothing)
    }

    @Test func sizeOfARegularFileIsRead() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ShowMyCopyTests-\(UUID().uuidString)")
        try Data(count: 321).write(to: url)
        defer {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Issue.record("Could not remove the temporary file: \(error)")
            }
        }
        #expect(FileSizeReader.sizeOfFile(at: url) == 321)
        #expect(FileSizeReader.sizeOfFile(at: url.deletingLastPathComponent()) == nil)
        #expect(FileSizeReader.sizeOfFile(at: url.appending(path: "missing")) == nil)
    }
}

@MainActor
struct ImageContentReaderTests {
    private let pasteboard = FakePasteboard()
    private let png = Data([0x89, 0x50, 0x4E, 0x47])

    @Test func prefersPNGOverTIFF() {
        pasteboard.copy([.tiff: Data([0x4D, 0x4D]), .png: png])
        #expect(
            ImageContentReader().read(from: pasteboard)
                == .image(CapturedImage(data: png, typeIdentifier: "public.png")))
    }

    @Test(arguments: ["public.jpeg", "public.heic", "public.tiff"])
    func readsEachSupportedType(type: String) {
        pasteboard.copy([NSPasteboard.PasteboardType(type): Data([1, 2])])
        #expect(
            ImageContentReader().read(from: pasteboard)
                == .image(CapturedImage(data: Data([1, 2]), typeIdentifier: type)))
    }

    @Test func otherImageTypesAreNotRead() {
        pasteboard.copy([NSPasteboard.PasteboardType("com.adobe.pdf"): Data([1])])
        #expect(ImageContentReader().read(from: pasteboard) == .nothing)
    }

    @Test func pictureNextToTextIsLeftForTheTextReaders() {
        // Word, Excel and Pages put a picture of the copied text next to it.
        pasteboard.copy([.string: Data("cells".utf8), .rtf: Data("{\\rtf1}".utf8), .png: png])
        #expect(ImageContentReader().read(from: pasteboard) == .nothing)
        #expect(pasteboard.dataReadCount == 0)
    }

    @Test func imageOverTheLimitIsSkippedBeforeAnythingIsMadeOfIt() {
        pasteboard.copy([.png: Data(count: 11)])
        #expect(ImageContentReader(maximumBytes: 10).read(from: pasteboard) == .tooLarge(limit: 10))
        pasteboard.copy([.png: Data(count: 10)])
        #expect(
            ImageContentReader(maximumBytes: 10).read(from: pasteboard)
                == .image(CapturedImage(data: Data(count: 10), typeIdentifier: "public.png")))
    }

    @Test func defaultLimitIsTwentyMegabytes() {
        #expect(ImageContentReader.defaultMaximumBytes == 20 * 1_048_576)
    }

    @Test func emptyImageDataIsNothing() {
        pasteboard.copy([.png: Data()])
        #expect(ImageContentReader().read(from: pasteboard) == .nothing)
    }
}

@MainActor
struct RichTextContentReaderTests {
    private let pasteboard = FakePasteboard()
    private let rtf = Data(#"{\rtf1 {\b bold}}"#.utf8)

    @Test func readsTheRTFWithItsPlainText() {
        pasteboard.copyRichText("bold", rtf: rtf)
        #expect(RichTextContentReader().read(from: pasteboard) == .content(.richText(rtf: rtf, plain: "bold")))
    }

    @Test func plainTextIsNotForIt() {
        pasteboard.copy("plain")
        #expect(RichTextContentReader().read(from: pasteboard) == .nothing)
    }

    @Test func rtfOverTheLimitIsKeptAsThePlainTextItReadFirst() {
        pasteboard.copyRichText("bold", rtf: Data(count: 11))
        #expect(RichTextContentReader(maximumBytes: 10).read(from: pasteboard) == .content(.text("bold")))
        #expect(pasteboard.dataReadTypes == [.string, .rtf])
    }

    /// macOS cannot tell the size of copied data before it is read, so the smaller form is read first: styled text
    /// whose plain text is over the limit is skipped without reading its RTF, which is larger still.
    @Test func plainTextOverItsLimitSkipsTheItemWithoutReadingTheRTF() {
        pasteboard.copyRichText(String(repeating: "a", count: 11), rtf: rtf)
        #expect(RichTextContentReader(textLimit: 10).read(from: pasteboard) == .tooLarge(limit: 10))
        #expect(pasteboard.dataReadTypes == [.string])
    }

    @Test func styledTextWithoutPlainTextIsNotRead() {
        pasteboard.copy([.rtf: rtf])
        #expect(RichTextContentReader().read(from: pasteboard) == .nothing)
        #expect(!pasteboard.dataReadTypes.contains(.rtf))
    }

    @Test func defaultLimitIsOneMegabyte() {
        #expect(RichTextContentReader.defaultMaximumBytes == 1_048_576)
    }
}

/// The readers together, in the order the monitor uses them.
@MainActor
struct StandardReadersTests {
    private let pasteboard = FakePasteboard()
    private let png = Data([0x89, 0x50, 0x4E, 0x47])

    private func read(
        readsImages: Bool = true,
        fromPasswordManager: Bool = false,
        savesPasswords: Bool = false
    ) -> CapturedItem {
        PasteboardSnapshotReader(
            pasteboard: pasteboard, contentReaders: PasteboardSnapshotReader.standardReaders(readsImages: readsImages)
        )
        .read(fromPasswordManager: fromPasswordManager, savesPasswords: savesPasswords)
    }

    @Test func orderIsFilesImagesRichTextText() {
        let readers = PasteboardSnapshotReader.standardReaders(readsImages: true)
        #expect(readers.count == 4)
        #expect(readers[0] is FileURLContentReader)
        #expect(readers[1] is ImageContentReader)
        #expect(readers[2] is RichTextContentReader)
        #expect(readers[3] is TextContentReader)
        #expect(!PasteboardSnapshotReader.standardReaders(readsImages: false).contains { $0 is ImageContentReader })
    }

    @Test func finderCopyIsFilesNotTheirNamesOrIcon() {
        let url = URL(filePath: "/Users/me/a.txt")
        pasteboard.copyFiles([url])
        guard case .content(.files(let files), isSecret: false) = read() else {
            Issue.record("A Finder copy is files")
            return
        }
        #expect(files.map(\.url) == [url])
    }

    @Test func styledTextWithAPictureIsRichText() {
        let rtf = Data("{\\rtf1 cells}".utf8)
        pasteboard.copy([.string: Data("cells".utf8), .rtf: rtf, .png: png])
        #expect(read() == .content(.richText(rtf: rtf, plain: "cells"), isSecret: false))
    }

    @Test func imageOnlyItemIsAnImage() {
        pasteboard.copy([.png: png])
        #expect(read() == .image(CapturedImage(data: png, typeIdentifier: "public.png")))
        #expect(read(readsImages: false) == .skipped(.unsupported))
    }

    @Test func tooLargeImageIsSkipped() {
        pasteboard.copy([.png: Data(count: ImageContentReader.defaultMaximumBytes + 1)])
        #expect(read() == .skipped(.tooLarge))
    }

    @Test func largeRTFIsKeptAsPlainTextReadOnce() {
        pasteboard.copyRichText("words", rtf: Data(count: RichTextContentReader.defaultMaximumBytes + 1))
        #expect(read() == .content(.text("words"), isSecret: false))
        #expect(pasteboard.dataReadTypes.filter { $0 == .string }.count == 1)
        #expect(pasteboard.dataReadTypes.filter { $0 == .rtf }.count == 1)
    }

    @Test func styledTextWithTooMuchPlainTextIsSkippedWithoutReadingTheRTF() {
        pasteboard.copyRichText(String(repeating: "a", count: TextContentReader.defaultMaximumBytes + 1), rtf: png)
        #expect(read() == .skipped(.tooLarge))
        #expect(!pasteboard.dataReadTypes.contains(.rtf))
    }

    @Test func secretRichTextIsKeptAsPlainText() {
        pasteboard.copyRichText("hunter2", markers: [PasteboardMarker.concealed])
        #expect(read(savesPasswords: true) == .content(.text("hunter2"), isSecret: true))
    }

    @Test func secretImageIsNeverKept() {
        pasteboard.copy([.png: png], markers: [PasteboardMarker.concealed])
        #expect(read(savesPasswords: true) == .skipped(.secret))
        #expect(read(savesPasswords: false) == .skipped(.secret))
    }

    @Test func filesCopiedFromAPasswordManagerAreKeptAsTextOnly() {
        pasteboard.copyFiles([URL(filePath: "/Users/me/vault.kdbx")])
        #expect(read(fromPasswordManager: true, savesPasswords: true) == .content(.text("vault.kdbx"), isSecret: true))
        #expect(pasteboard.fileURLReadCount == 0)
    }

    @Test func imageMarkedAsSecretWhileReadIsNotKept() {
        pasteboard.copy([.png: png])
        pasteboard.whileReadingString = { $0.addMarker(PasteboardMarker.concealed) }
        #expect(read(savesPasswords: true) == .skipped(.secret))
    }

    @Test func filesMarkedAsSecretWhileReadAreKeptAsText() {
        pasteboard.copyFiles([URL(filePath: "/Users/me/secret.txt")])
        pasteboard.whileReadingString = { $0.addMarker(PasteboardMarker.concealed) }
        #expect(read(savesPasswords: true) == .content(.text("secret.txt"), isSecret: true))
    }

    @Test(arguments: PasteboardMarker.alwaysSkipped.sorted())
    func markedImagesAndFilesAreNeverRead(marker: String) {
        pasteboard.copy([.png: png], markers: [marker])
        #expect(read(savesPasswords: true) == .skipped(.marked))
        pasteboard.copyFiles([URL(filePath: "/a")], markers: [marker])
        #expect(read(savesPasswords: true) == .skipped(.marked))
        #expect(pasteboard.dataReadCount == 0)
        #expect(pasteboard.fileURLReadCount == 0)
    }
}
