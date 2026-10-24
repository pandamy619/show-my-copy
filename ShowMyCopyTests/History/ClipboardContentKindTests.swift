import Foundation
import Testing

@testable import ShowMyCopy

struct ClipboardContentKindTests {
    private let hasher = SHA256ContentHasher()
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(_ content: ClipboardContent) -> ClipboardEntry {
        ClipboardEntry(content: content, contentHash: hasher.hash(content), date: date, sourceApp: nil)
    }

    // MARK: Rich text

    @Test func richTextDescribesItselfByItsPlainText() {
        let content = ContentFixtures.richText("Bold text")
        #expect(content.kind == .richText)
        #expect(content.text == "Bold text")
        #expect(content.searchableText == "Bold text")
        #expect(content.byteSize == ContentFixtures.rtf.count + 9)
        #expect(content.blobIDs.isEmpty)
        #expect(content.canBeConcealed)
    }

    @Test func richTextCanonicalBytesHoldTheLengthPrefixedRTFThenThePlainText() {
        let content = ClipboardContent.richText(rtf: Data([0xAA, 0xBB]), plain: "e\u{301}")
        #expect(content.canonicalBytes == Data([0x02, 0, 0, 0, 2, 0xAA, 0xBB, 0xC3, 0xA9]))
    }

    @Test func sameWordsWithOtherStylingAreOtherContent() {
        let bold = ContentFixtures.richText("text", rtf: Data(#"{\rtf1 {\b text}}"#.utf8))
        let italic = ContentFixtures.richText("text", rtf: Data(#"{\rtf1 {\i text}}"#.utf8))
        #expect(hasher.hash(bold) != hasher.hash(italic))
        #expect(hasher.hash(bold) != hasher.hash(.text("text")))
    }

    @Test func richTextIsNotConfusedByWhereTheRTFEnds() {
        // Without the length prefix both would be the bytes "ab" + "c".
        let first = ClipboardContent.richText(rtf: Data("ab".utf8), plain: "c")
        let second = ClipboardContent.richText(rtf: Data("a".utf8), plain: "bc")
        #expect(first.canonicalBytes != second.canonicalBytes)
    }

    @Test func richTextEntryPreviewsAndSearchesItsPlainText() {
        let richEntry = entry(ContentFixtures.richText("  Café\n\nmenu"))
        #expect(richEntry.previewText == "Café\nmenu")
        #expect(richEntry.searchKey == "  cafe\n\nmenu")
    }

    // MARK: Images

    @Test func imageDescribesItself() throws {
        let reference = ContentFixtures.imageReference(byteSize: 1000, thumbnailBytes: 100)
        let content = ClipboardContent.image(reference)
        #expect(content.kind == .image)
        #expect(content.text == nil)
        #expect(content.searchableText == nil)
        #expect(content.byteSize == 1100)
        let thumbnail = try #require(reference.thumbnail)
        #expect(content.blobIDs == [reference.blobID, thumbnail.blobID])
        #expect(content.image == reference)
        #expect(!content.canBeConcealed)
    }

    @Test func imageWithoutThumbnailCountsItsDataOnly() {
        let content = ContentFixtures.image(byteSize: 1000, thumbnailBytes: nil)
        #expect(content.byteSize == 1000)
        #expect(content.blobIDs.count == 1)
    }

    @Test func imageCanonicalBytesAreTheDigestOfItsData() {
        let reference = ContentFixtures.imageReference(hashByte: 0xAB)
        #expect(ClipboardContent.image(reference).canonicalBytes == Data([0x03] + [UInt8](repeating: 0xAB, count: 32)))
    }

    @Test func sameImageDataStoredTwiceIsTheSameContent() {
        let first = ContentFixtures.image(hashByte: 5)
        let second = ContentFixtures.image(hashByte: 5)
        #expect(first != second)
        #expect(hasher.hash(first) == hasher.hash(second))
        #expect(hasher.hash(first) != hasher.hash(ContentFixtures.image(hashByte: 6)))
    }

    @Test func imageEntryShowsItsFormatAndSizeAndIsNotSearchedByText() {
        let imageEntry = entry(ContentFixtures.image())
        #expect(imageEntry.previewText == "PNG 640 × 480")
        #expect(imageEntry.searchKey == nil)
        #expect(imageEntry.byteSize == 1100)
    }

    @Test(arguments: [
        ("public.png", "PNG"), ("public.jpeg", "JPEG"), ("public.heic", "HEIC"), ("public.tiff", "TIFF"),
        ("com.example.webp", "WEBP"),
    ])
    func formatNames(typeIdentifier: String, name: String) {
        let reference = ImageReference(
            blobID: BlobID(), typeIdentifier: typeIdentifier, pixelWidth: 1, pixelHeight: 1, byteSize: 1,
            contentHash: ContentHash(bytes: [1]), thumbnail: nil)
        #expect(reference.formatName == name)
    }

    // MARK: Files

    @Test func filesDescribeThemselvesByTheirNames() {
        let content = ContentFixtures.files("/Users/me/Report.pdf", "/Users/me/Photos")
        #expect(content.kind == .files)
        #expect(content.text == nil)
        #expect(content.searchableText == "Report.pdf\nPhotos")
        // The paths and names, not the files.
        #expect(content.byteSize == "/Users/me/Report.pdf".utf8.count + 10 + "/Users/me/Photos".utf8.count + 6)
        #expect(content.blobIDs.isEmpty)
        #expect(!content.canBeConcealed)
    }

    @Test func fileNameDefaultsToTheLastPathComponent() {
        let file = FileReference(url: URL(filePath: "/Users/me/Отчёт 1.pdf"))
        #expect(file.name == "Отчёт 1.pdf")
        #expect(file.path == "/Users/me/Отчёт 1.pdf")
        #expect(file.byteSize == nil)
    }

    @Test func filesCanonicalBytesAreTheLengthPrefixedPaths() {
        let content = ContentFixtures.files("/a", "/bc")
        let expected = Data([0x04, 0, 0, 0, 2]) + Data("/a".utf8) + Data([0, 0, 0, 3]) + Data("/bc".utf8)
        #expect(content.canonicalBytes == expected)
    }

    @Test func filesAreIdentifiedByPathNotBySize() {
        let small = ClipboardContent.files([ContentFixtures.file("/a.txt", byteSize: 1)])
        let large = ClipboardContent.files([ContentFixtures.file("/a.txt", byteSize: 2)])
        #expect(hasher.hash(small) == hasher.hash(large))
        #expect(hasher.hash(small) != hasher.hash(ContentFixtures.files("/b.txt")))
        #expect(hasher.hash(ContentFixtures.files("/a", "/b")) != hasher.hash(ContentFixtures.files("/b", "/a")))
    }

    @Test func filesEntryPreviewsAndSearchesTheNames() {
        let filesEntry = entry(ContentFixtures.files("/Users/me/Résumé.pdf", "/Users/me/b.txt", "/Users/me/c.txt"))
        #expect(filesEntry.previewText == "Résumé.pdf\nb.txt…")
        #expect(filesEntry.searchKey == "resume.pdf\nb.txt\nc.txt")
    }

    // MARK: All kinds

    @Test func kindsHaveDistinctTagsSoNoContentsShareAHash() {
        let contents: [ClipboardContent] = [
            .text("a"), ContentFixtures.richText("a"), ContentFixtures.image(), ContentFixtures.files("/a"),
        ]
        #expect(Set(contents.map { $0.canonicalBytes.first }).count == contents.count)
        #expect(Set(contents.map(\.kind)) == Set(ClipboardContent.Kind.allCases))
    }

    @Test func kindRawValuesAreSavedAndNeverChange() {
        #expect(ClipboardContent.Kind.allCases.map(\.rawValue) == ["text", "richText", "image", "files"])
    }
}

struct ContentHashHexTests {
    @Test func hexRoundTrips() {
        let hash = ContentHash(bytes: [0x00, 0x0F, 0xAB, 0xFF])
        #expect(ContentHash(hex: hash.description) == hash)
        #expect(ContentHash(hex: "000FABFF") == hash)
    }

    @Test(arguments: ["", "abc", "zz", "0g", "-1"])
    func invalidHexIsRejected(hex: String) {
        #expect(ContentHash(hex: hex) == nil)
    }
}

struct FileAvailabilityTests {
    @Test func fileThatExistsIsAvailableAndAMissingOneMayBeUnavailable() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ShowMyCopyTests-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Issue.record("Could not remove the temporary file: \(error)")
            }
        }
        let checker = FileSystemAvailabilityChecker()
        #expect(checker.availability(of: FileReference(url: url)) == .available)
        let missing = url.deletingLastPathComponent().appending(path: "missing-\(UUID().uuidString)")
        #expect(checker.availability(of: FileReference(url: missing)) == .mayBeUnavailable)
    }

    @Test func filesOnNetworkVolumesAndAutomountedPathsAreNotChecked() {
        let checker = FileSystemAvailabilityChecker(
            paths: CopiedPaths(
                volumes: FakeVolumes([
                    MountedVolume(mountPoint: "/", fileSystem: "apfs", isLocal: true),
                    MountedVolume(mountPoint: "/Volumes/share", fileSystem: "smbfs", isLocal: false),
                ])))
        #expect(checker.availability(of: ContentFixtures.file("/Volumes/share/a.txt")) == .notChecked)
        #expect(checker.availability(of: ContentFixtures.file("/net/tracker.example/x")) == .notChecked)
    }
}

/// Availability is checked off the main actor, within a budget (`TimeLimit`, tested on its own) that holds even when a
/// check is stuck.
struct FileAvailabilityProbeTests {
    @Test func everyFileGetsAnAnswer() async {
        let files = [ContentFixtures.file("/Users/me/a.txt"), ContentFixtures.file("/Users/me/gone.txt")]
        let checker = FakeAvailabilityChecker(missing: ["/Users/me/gone.txt"])
        #expect(await FileAvailabilityProbe.check(files, with: checker) == [.available, .mayBeUnavailable])
    }

    @Test func theBudgetIsShort() {
        #expect(FileAvailabilityProbe.budget == .seconds(2))
    }

    @Test func aRowWithFilesNotCheckedHasNoMark() {
        #expect(FileAvailabilityProbe.summary([.available, .notChecked]) == .available)
        #expect(FileAvailabilityProbe.summary([.notChecked, .mayBeUnavailable]) == .mayBeUnavailable)
    }
}
