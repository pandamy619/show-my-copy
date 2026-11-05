import Foundation
import Testing

@testable import ShowMyCopy

/// What dragging a history row into another app hands over: as copying it back would, on the drag pasteboard only,
/// and nothing for a password.
struct EntryDragTests {
    /// 5 November 2026, 16:10:30 in Moscow (UTC+3).
    private let copiedAt = Date(timeIntervalSince1970: 1_793_884_230)
    private let moscow = TimeZone(identifier: "Europe/Moscow") ?? .gmt

    private func entry(_ content: ClipboardContent, concealed: Bool = false) -> ClipboardEntry {
        ClipboardEntry(
            content: content, contentHash: SHA256ContentHasher().hash(content), date: copiedAt, sourceApp: nil,
            isConcealed: concealed, expiresAt: concealed ? copiedAt + 600 : nil)
    }

    private func dragged(_ entry: ClipboardEntry, canReadImages: Bool = true) -> EntryDrag? {
        EntryDrag(
            entry: entry, canReadImages: canReadImages, imageTitle: { day, time in "Image \(day) at \(time)" },
            timeZone: moscow)
    }

    // MARK: - Kinds

    @Test func textIsPlainText() throws {
        let drag = try #require(dragged(entry(.text("Hello, world"))))

        let plain = EntryDrag.Representation(typeIdentifier: "public.utf8-plain-text", data: Data("Hello, world".utf8))
        #expect(drag.items == [.data([plain])])
    }

    @Test func richTextIsItsRTFAndThenItsPlainText() throws {
        let drag = try #require(dragged(entry(ContentFixtures.richText("Bold text"))))

        #expect(
            drag.items == [
                .data([
                    EntryDrag.Representation(typeIdentifier: "public.rtf", data: ContentFixtures.rtf),
                    EntryDrag.Representation(typeIdentifier: "public.utf8-plain-text", data: Data("Bold text".utf8)),
                ])
            ])
    }

    @Test func anImageIsPromisedAsAFileInItsOwnFormat() throws {
        let image = ContentFixtures.imageReference()
        let drag = try #require(dragged(entry(.image(image))))

        // Only the blob's ID: the data is read when the app it is dropped on asks for it, not now.
        #expect(
            drag.items == [
                .image(
                    EntryDrag.PromisedImage(
                        blobID: image.blobID, typeIdentifier: "public.png", fileName: "Image 2026-11-05 at 16.10.png"))
            ])
    }

    @Test func filesAreTheirURLsOneItemEach() throws {
        let drag = try #require(dragged(entry(ContentFixtures.files("/Users/me/a.txt", "/Users/me/Photos"))))

        #expect(
            drag.items == [
                .file(URL(filePath: "/Users/me/a.txt")),
                .file(URL(filePath: "/Users/me/Photos")),
            ])
    }

    // MARK: - What cannot be dragged

    @Test func aPasswordCannotBeDraggedAndPutsNothingOnTheDrag() {
        let password = entry(.text("hunter2"), concealed: true)

        #expect(!EntryDrag.canDrag(password, canReadImages: true))
        #expect(dragged(password) == nil)
    }

    @Test func aStyledPasswordCannotBeDraggedEither() {
        let password = entry(ContentFixtures.richText("hunter2"), concealed: true)

        #expect(!EntryDrag.canDrag(password, canReadImages: true))
        #expect(dragged(password) == nil)
    }

    @Test func anImageNeedsTheBlobStore() {
        let image = entry(ContentFixtures.image())

        #expect(!EntryDrag.canDrag(image, canReadImages: false))
        #expect(dragged(image, canReadImages: false) == nil)
        #expect(EntryDrag.canDrag(image, canReadImages: true))
    }

    @Test func everyOtherKindCanBeDragged() {
        #expect(EntryDrag.canDrag(entry(.text("")), canReadImages: false))
        #expect(EntryDrag.canDrag(entry(ContentFixtures.richText()), canReadImages: false))
        #expect(EntryDrag.canDrag(entry(ContentFixtures.files("/tmp/a")), canReadImages: false))
        #expect(!EntryDrag.canDrag(entry(.files([])), canReadImages: true))
    }

    // MARK: - File names

    @Test func theFileNameHasTheDayAndTimeOfTheCopyInTheTimeZone() {
        let stamp = EntryDrag.dayAndTime(of: copiedAt, in: moscow)
        #expect(stamp.day == "2026-11-05")
        #expect(stamp.time == "16.10")

        let utc = EntryDrag.dayAndTime(of: copiedAt, in: .gmt)
        #expect(utc.time == "13.10")
    }

    @Test func theDayAndTimeArePaddedWithZeros() {
        // 2 March 2026, 04:05 UTC.
        let stamp = EntryDrag.dayAndTime(of: Date(timeIntervalSince1970: 1_772_424_300), in: .gmt)

        #expect(stamp.day == "2026-03-02")
        #expect(stamp.time == "04.05")
    }

    @Test func eachFormatGetsItsExtension() {
        #expect(EntryDrag.fileName("Image", typeIdentifier: "public.png") == "Image.png")
        #expect(EntryDrag.fileName("Image", typeIdentifier: "public.jpeg") == "Image.jpeg")
        #expect(EntryDrag.fileName("Image", typeIdentifier: "public.heic") == "Image.heic")
        #expect(EntryDrag.fileName("Image", typeIdentifier: "public.tiff") == "Image.tiff")
        #expect(EntryDrag.fileName("Image", typeIdentifier: "com.example.unknown") == "Image")
        #expect(ImageReference.supportedTypes.allSatisfy { EntryDrag.fileName("x", typeIdentifier: $0) != "x" })
    }

    @Test func aTitleNeverMakesAPath() {
        #expect(EntryDrag.fileName("Image 05/11 at 16:10", typeIdentifier: "public.png") == "Image 05-11 at 16-10.png")
    }

    // MARK: - Starting a drag

    @Test func aPressBecomesADragOnlyOnceTheMouseMoved() {
        let start = CGPoint(x: 100, y: 100)

        #expect(!EntryDrag.isDrag(from: start, to: start))
        #expect(!EntryDrag.isDrag(from: start, to: CGPoint(x: 102, y: 102)))
        #expect(EntryDrag.isDrag(from: start, to: CGPoint(x: 100 + EntryDrag.minimumDistance, y: 100)))
        #expect(EntryDrag.isDrag(from: start, to: CGPoint(x: 100, y: 100 - EntryDrag.minimumDistance)))
    }
}
