import Foundation
import Testing

@testable import ShowMyCopy

struct StoredEntryCoderKindTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let hasher = SHA256ContentHasher()
    private let coder = StoredEntryCoder(sealer: FakeSecretSealer(), hasher: SHA256ContentHasher())

    private func entry(_ content: ClipboardContent, concealed: Bool = false) -> ClipboardEntry {
        ClipboardEntry(
            content: content, contentHash: hasher.hash(content), date: date,
            sourceApp: SourceApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit"), isConcealed: concealed,
            expiresAt: concealed ? date + 600 : nil)
    }

    private func roundTrip(_ content: ClipboardContent) throws -> StoredEntryRecord {
        let original = entry(content)
        let record = try #require(try coder.record(for: original))
        #expect(coder.decode(record) == .entry(original))
        return record
    }

    @Test func richTextRoundTrips() throws {
        let record = try roundTrip(ContentFixtures.richText("Жирный текст"))
        #expect(record.kind == "richText")
        #expect(record.schemaVersion == 2)
        #expect(record.blobIDs.isEmpty)
        #expect(record.previewText == "Жирный текст")
        #expect(record.byteSize == ContentFixtures.richText("Жирный текст").byteSize)
    }

    @Test func imageRecordHoldsItsBlobIDsAndMetadataButNotTheImage() throws {
        let reference = ContentFixtures.imageReference(byteSize: 5_000_000, thumbnailBytes: 30_000)
        let record = try roundTrip(.image(reference))
        #expect(record.kind == "image")
        #expect(record.schemaVersion == 2)
        let thumbnail = try #require(reference.thumbnail)
        #expect(record.blobIDs == [reference.blobID.uuid, thumbnail.blobID.uuid])
        #expect(record.byteSize == 5_030_000)
        #expect(record.payload.count < 200)
    }

    @Test func imageWithoutThumbnailRoundTrips() throws {
        let record = try roundTrip(ContentFixtures.image(thumbnailBytes: nil))
        #expect(record.blobIDs.count == 1)
    }

    @Test func filesRoundTripWithNamesAndSizes() throws {
        let content = ClipboardContent.files([
            FileReference(url: URL(filePath: "/Users/me/My Files/Отчёт #1.pdf"), byteSize: 12_345),
            FileReference(url: URL(filePath: "/Users/me/Photos", directoryHint: .isDirectory), name: "Фото"),
        ])
        let record = try roundTrip(content)
        #expect(record.kind == "files")
        #expect(record.blobIDs.isEmpty)
    }

    @Test func concealedRichTextIsSealed() throws {
        let secret = entry(ContentFixtures.richText("hunter2"), concealed: true)
        let record = try #require(try coder.record(for: secret))
        #expect(record.contentHash == nil)
        #expect(record.previewText == nil)
        #expect(record.byteSize == 0)
        #expect(record.payload.range(of: Data("hunter2".utf8)) == nil)
        #expect(coder.decode(record) == .entry(secret))
    }

    @Test func richTextPayloadLayoutIsFixed() {
        // Saved on disk: changing it makes saved entries unreadable.
        let payload = ClipboardContent.richText(rtf: Data([0xAA]), plain: "b").storedPayload
        #expect(payload == Data([1, 0, 0, 0, 1, 0xAA, 0, 0, 0, 1, 0x62]))
    }

    @Test func textPayloadIsStillPlainUTF8() {
        #expect(ClipboardContent.text("hi").storedPayload == Data("hi".utf8))
    }

    @Test(arguments: [ClipboardContent.Kind.richText, .image, .files])
    func damagedPayloadsAreUnreadable(kind: ClipboardContent.Kind) throws {
        let content: ClipboardContent =
            switch kind {
            case .text, .richText: ContentFixtures.richText()
            case .image: ContentFixtures.image()
            case .files: ContentFixtures.files("/a", "/b")
            }
        let record = try #require(try coder.record(for: entry(content)))
        #expect(coder.decode(record.replacingPayload(with: record.payload.dropLast())) == .unreadable)
        #expect(coder.decode(record.replacingPayload(with: record.payload + Data([0]))) == .unreadable)
        var otherFormat = record.payload
        otherFormat[otherFormat.startIndex] = 2
        #expect(coder.decode(record.replacingPayload(with: otherFormat)) == .unreadable)
        #expect(coder.decode(record.replacingPayload(with: Data())) == .unreadable)
    }

    @Test func filesThatAreNotFileURLsAreUnreadable() throws {
        let content = ClipboardContent.files([FileReference(url: URL(filePath: "/a"))])
        let record = try #require(try coder.record(for: entry(content)))
        // The same length, so only the scheme differs.
        let replaced = try #require(record.payload.range(of: Data("file:///a".utf8)))
        var payload = record.payload
        payload.replaceSubrange(replaced, with: Data("http://ab".utf8))
        #expect(coder.decode(record.replacingPayload(with: payload)) == .unreadable)
    }

    @Test func emptyFileListIsUnreadable() throws {
        let record = try #require(try coder.record(for: entry(ContentFixtures.files("/a"))))
        let payload = Data([1, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(coder.decode(record.replacingPayload(with: payload)) == .unreadable)
    }

    @Test func versionTwoIsReadAndNewerIsLeftAlone() throws {
        let record = try #require(try coder.record(for: entry(ContentFixtures.image())))
        #expect(coder.supports(record))
        #expect(!coder.supports(record.replacingSchemaVersion(with: 3)))
    }
}

@MainActor
struct PersistentHistoryStoreKindTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func richTextAndFilesSurviveARestart() throws {
        let disk = FakeHistoryPersistence()
        let store = disk.makeStore(now: start)
        store.record(ContentFixtures.files("/Users/me/a.txt", "/Users/me/b"), sourceApp: nil, at: start)
        store.record(ContentFixtures.richText("styled"), sourceApp: nil, at: start + 1)
        store.record(text: "plain", sourceApp: nil, at: start + 2)

        let restarted = disk.makeStore(now: start + 3)
        #expect(restarted.entries == store.entries)
        #expect(restarted.entries.map(\.kind) == [.text, .richText, .files])
    }
}
