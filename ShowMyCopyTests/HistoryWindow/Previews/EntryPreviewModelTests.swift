import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct EntryPreviewModelTests {
    private let blobs = ReadCountingBlobStore()
    private let decoder = FakeImageDecoder(width: 4000, height: 3000)
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeModel(missing: Set<String> = []) -> EntryPreviewModel {
        EntryPreviewModel(
            services: PreviewServices(
                blobs: blobs,
                images: decoder,
                richText: FakeRichTextRenderer(),
                fileAvailability: FakeAvailabilityChecker(missing: missing)
            )
        )
    }

    private func entry(_ content: ClipboardContent, isConcealed: Bool = false) -> ClipboardEntry {
        ClipboardEntry(
            content: content,
            contentHash: SHA256ContentHasher().hash(content),
            date: now,
            sourceApp: nil,
            isConcealed: isConcealed
        )
    }

    @Test func startsClosed() {
        let model = makeModel()
        #expect(!model.isOpen)
        #expect(model.content == nil)
    }

    @Test func textIsShownSanitized() throws {
        let model = makeModel()
        let entry = entry(.text("line one\nline\u{202E} two"))
        #expect(model.open(entry))
        #expect(model.entryID == entry.id)
        guard case .text(let text) = try #require(model.content) else {
            Issue.record("expected text")
            return
        }
        #expect(text == "line one\nline two")
    }

    @Test func passwordIsNeverPreviewed() {
        let model = makeModel()
        let password = entry(.text("hunter2"), isConcealed: true)
        #expect(!EntryPreviewModel.canPreview(password))
        #expect(!model.open(password))
        #expect(!model.isOpen)
        #expect(model.content == nil)

        // Moving to a password from an open preview closes it.
        #expect(model.open(entry(.text("visible"))))
        #expect(!model.open(password))
        #expect(!model.isOpen)
    }

    @Test func fullImageIsReadOnlyWhenOpenedAndDroppedWhenClosed() async throws {
        let image = try ContentFixtures.storedImage(in: blobs)
        let model = makeModel()
        let entry = entry(.image(image))
        #expect(blobs.readCount(of: image.blobID) == 0)

        model.open(entry)
        guard case .image(let shown, let state) = try #require(model.content) else {
            Issue.record("expected an image")
            return
        }
        #expect(shown == image)
        #expect(state.isLoading)

        await model.pendingLoad?.value
        guard case .image(_, .loaded(let decoded)) = try #require(model.content) else {
            Issue.record("expected a loaded image")
            return
        }
        let fake = try #require(decoded as? FakePreviewImage)
        #expect(fake.data == Data(repeating: 7, count: 1000))
        #expect(blobs.readCount(of: image.blobID) == 1)
        #expect(blobs.readCount(of: try #require(image.thumbnail).blobID) == 0)
        // Decoded at most at the preview's size, not at 4000 × 3000.
        #expect(decoder.requestedPixelSizes == [EntryPreviewModel.maximumImagePixelSize])
        #expect(fake.pixelWidth == 2048)

        model.close()
        #expect(!model.isOpen)
        #expect(model.content == nil)
    }

    @Test func imageThatCannotBeReadFails() async throws {
        let model = makeModel()
        model.open(entry(.image(ContentFixtures.imageReference())))
        await model.pendingLoad?.value
        guard case .image(_, let state) = try #require(model.content) else {
            Issue.record("expected an image")
            return
        }
        #expect(state.isFailed)
    }

    @Test func imageFailsAtOnceWithoutBlobStore() throws {
        let model = EntryPreviewModel(services: PreviewServices())
        model.open(entry(.image(ContentFixtures.imageReference())))
        guard case .image(_, let state) = try #require(model.content) else {
            Issue.record("expected an image")
            return
        }
        #expect(state.isFailed)
        #expect(model.pendingLoad == nil)
    }

    @Test func loadThatFinishesAfterClosingIsDropped() async throws {
        let image = try ContentFixtures.storedImage(in: blobs)
        let model = makeModel()
        model.open(entry(.image(image)))
        let load = model.pendingLoad
        model.close()
        await load?.value
        #expect(model.content == nil)
        #expect(!model.isOpen)
    }

    @Test func loadOfAnEarlierEntryDoesNotReplaceTheCurrentOne() async throws {
        let image = try ContentFixtures.storedImage(in: blobs)
        let model = makeModel()
        model.open(entry(.image(image)))
        let earlier = model.pendingLoad
        let text = entry(.text("now shown"))
        model.open(text)
        await earlier?.value
        #expect(model.entryID == text.id)
        guard case .text = try #require(model.content) else {
            Issue.record("expected text")
            return
        }
    }

    @Test func richTextIsRenderedWithThePlainTextMeanwhile() async throws {
        let model = makeModel()
        model.open(entry(ContentFixtures.richText("Bold\u{202E} text")))
        guard case .richText(let state, let plain) = try #require(model.content) else {
            Issue.record("expected rich text")
            return
        }
        #expect(state.isLoading)
        #expect(plain == "Bold text")

        await model.pendingLoad?.value
        guard case .richText(.loaded(let rendered), _) = try #require(model.content) else {
            Issue.record("expected rendered rich text")
            return
        }
        #expect(rendered as? FakeRenderedRichText == FakeRenderedRichText(rtf: ContentFixtures.rtf))
    }

    @Test func unreadableRichTextFallsBackToPlainText() async throws {
        let model = makeModel()
        model.open(entry(.richText(rtf: FakeRichTextRenderer.unreadable, plain: "plain")))
        await model.pendingLoad?.value
        guard case .richText(let state, let plain) = try #require(model.content) else {
            Issue.record("expected rich text")
            return
        }
        #expect(state.isFailed)
        #expect(plain == "plain")
    }

    @Test func richTextWithoutRendererShowsPlainText() throws {
        let model = EntryPreviewModel(services: PreviewServices())
        model.open(entry(ContentFixtures.richText()))
        guard case .richText(let state, let plain) = try #require(model.content) else {
            Issue.record("expected rich text")
            return
        }
        #expect(state.isFailed)
        #expect(plain == "Bold text")
    }

    @Test func filesAreListedThenMarkedWhenChecked() async throws {
        let model = makeModel(missing: ["/tmp/gone.txt"])
        let files: [FileReference] = [
            ContentFixtures.file("/tmp/here.txt", byteSize: 1200),
            ContentFixtures.file("/tmp/gone.txt", byteSize: nil),
            FileReference(url: URL(filePath: "/tmp/odd"), name: "evil\u{202E}txt.exe"),
        ]
        model.open(entry(.files(files)))
        guard case .files(let listed) = try #require(model.content) else {
            Issue.record("expected files")
            return
        }
        #expect(listed.map(\.name) == ["here.txt", "gone.txt", "eviltxt.exe"])
        #expect(listed.map(\.byteSize) == [1200, nil, nil])
        #expect(listed.allSatisfy { $0.availability == nil })

        await model.pendingLoad?.value
        guard case .files(let checked) = try #require(model.content) else {
            Issue.record("expected files")
            return
        }
        #expect(checked.map(\.availability) == [.available, .mayBeUnavailable, .available])
        #expect(checked.map(\.path) == ["/tmp/here.txt", "/tmp/gone.txt", "/tmp/odd"])
    }

    @Test func openingTheSameEntryAgainKeepsWhatIsLoaded() async throws {
        let image = try ContentFixtures.storedImage(in: blobs)
        let model = makeModel()
        let entry = entry(.image(image))
        model.open(entry)
        await model.pendingLoad?.value
        model.open(entry)
        #expect(model.content.map { if case .image(_, .loaded) = $0 { true } else { false } } == true)
        #expect(blobs.readCount(of: image.blobID) == 1)
    }

    @Test func fileAvailabilitySummaryMarksAnyMissingFile() async {
        let checker = FakeAvailabilityChecker(missing: ["/b"])
        let files = [ContentFixtures.file("/a"), ContentFixtures.file("/b")]
        let checked = await FileAvailabilityProbe.check(files, with: checker)
        #expect(checked == [.available, .mayBeUnavailable])
        #expect(FileAvailabilityProbe.summary(checked) == .mayBeUnavailable)
        #expect(FileAvailabilityProbe.summary([.available]) == .available)
    }
}
