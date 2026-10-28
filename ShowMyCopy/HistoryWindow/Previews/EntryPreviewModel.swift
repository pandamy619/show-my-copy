import Foundation
import Observation

/// What the history window needs to show thumbnails and previews. The platform pieces are nil in tests and when the
/// app keeps no images; rows and previews then show placeholders and plain text.
struct PreviewServices: Sendable {
    /// Where image data and thumbnails are kept.
    let blobs: (any BlobStore)?
    let images: (any PreviewImageDecoding)?
    let richText: (any RichTextRendering)?
    let fileAvailability: any FileAvailabilityChecking

    init(
        blobs: (any BlobStore)? = nil,
        images: (any PreviewImageDecoding)? = nil,
        richText: (any RichTextRendering)? = nil,
        fileAvailability: any FileAvailabilityChecking = FileSystemAvailabilityChecker()
    ) {
        self.blobs = blobs
        self.images = images
        self.richText = richText
        self.fileAvailability = fileAvailability
    }
}

/// The large preview of the selected entry in the history window.
///
/// Opening it is the only time the full image is read: rows show thumbnails. The image is decoded off the main
/// actor at most `maximumImagePixelSize` pixels on its longer side, and closing the preview drops it. Rich text is
/// rendered off the main actor by a `RichTextRendering`, which makes it safe to show; until it is ready, or when it
/// cannot be read, the plain text is shown. Files are listed with a mark on those that may be unavailable, checked
/// when the preview opens.
@MainActor
@Observable
final class EntryPreviewModel {
    enum Content {
        case text(String)
        /// The styled text once rendered, and the plain text to show until then or instead.
        case richText(PreviewLoadState<any RenderedRichText>, plain: String)
        case image(ImageReference, PreviewLoadState<any PreviewImage>)
        case files([FilePreviewItem])
    }

    /// Large enough for the preview at twice the panel's size, small enough to keep a 50-megapixel image from
    /// taking hundreds of megabytes: at most 16 MB decoded.
    static let maximumImagePixelSize = 2048

    private let services: PreviewServices

    /// The entry the preview shows, or nil when it is closed.
    private(set) var entryID: ClipboardEntry.ID?
    private(set) var content: Content?

    /// The content of the open entry that `content` shows, to tell when the history changes it.
    @ObservationIgnored private var shownContent: ClipboardContent?
    /// Counts opens, so a load that finishes after the preview moved on is dropped.
    @ObservationIgnored private var generation = 0
    /// The load started by the last `open`. Tests await it.
    @ObservationIgnored private(set) var pendingLoad: Task<Void, Never>?

    init(services: PreviewServices) {
        self.services = services
    }

    var isOpen: Bool {
        entryID != nil
    }

    /// A password is never previewed, revealed or not: the preview would show it larger and for longer.
    static func canPreview(_ entry: ClipboardEntry) -> Bool {
        !entry.isConcealed
    }

    /// Shows `entry`. Returns false, and closes the preview, for an entry that cannot be previewed. Called again
    /// for the open entry after the history changed it, it shows what the entry holds now (`update(to:)`).
    @discardableResult
    func open(_ entry: ClipboardEntry) -> Bool {
        guard Self.canPreview(entry) else {
            close()
            return false
        }
        guard entry.id != entryID else {
            update(to: entry.content)
            return true
        }
        close()
        generation += 1
        entryID = entry.id
        shownContent = entry.content
        start(entry.content, generation: generation)
        return true
    }

    /// Hides the preview and drops what it loaded, the full image included.
    func close() {
        pendingLoad?.cancel()
        pendingLoad = nil
        shownContent = nil
        if entryID != nil {
            entryID = nil
        }
        if content != nil {
            content = nil
        }
    }

    /// The open entry changed in the history after the preview opened: its image's data was saved, or its files
    /// got their thumbnails and sizes (see `CaptureEnrichment`). What is shown already stays: a loaded image is not
    /// read again, its bytes are the same, and files keep the availability checked for them.
    private func update(to newContent: ClipboardContent) {
        guard newContent != shownContent else {
            return
        }
        shownContent = newContent
        switch (newContent, content) {
        case (.image(let image), .image(_, .loaded(let decoded))):
            content = .image(image, .loaded(decoded))
        case (.files(let files), .files(let items)) where files.count == items.count:
            content = .files(
                zip(files, items).map { file, item in
                    FilePreviewItem(id: item.id, file: file, availability: item.availability)
                })
        default:
            pendingLoad?.cancel()
            generation += 1
            start(newContent, generation: generation)
        }
    }

    private func start(_ content: ClipboardContent, generation: Int) {
        switch content {
        case .text(let text):
            self.content = .text(PreviewText.sanitized(text))
        case .richText(let rtf, let plain):
            loadRichText(rtf, plain: PreviewText.sanitized(plain), generation: generation)
        case .image(let image):
            loadImage(image, generation: generation)
        case .files(let files):
            checkFiles(files, generation: generation)
        }
    }

    private func loadRichText(_ rtf: Data, plain: String, generation: Int) {
        guard let renderer = services.richText else {
            content = .richText(.failed, plain: plain)
            return
        }
        content = .richText(.loading, plain: plain)
        pendingLoad = Task { [weak self] in
            let rendered = await RichTextPreviewPolicy.render(rtf, with: renderer)
            guard let self, self.generation == generation, !Task.isCancelled else {
                return
            }
            content = .richText(rendered.map { .loaded($0) } ?? .failed, plain: plain)
        }
    }

    private func loadImage(_ image: ImageReference, generation: Int) {
        guard let blobs = services.blobs, let decoder = services.images else {
            content = .image(image, .failed)
            return
        }
        content = .image(image, .loading)
        pendingLoad = Task { [weak self] in
            let decoded = await PreviewImageLoader.load(
                image.blobID, from: blobs, decoder: decoder, maximumPixelSize: Self.maximumImagePixelSize)
            guard let self, self.generation == generation, !Task.isCancelled else {
                return
            }
            content = .image(image, decoded.map { .loaded($0) } ?? .failed)
        }
    }

    private func checkFiles(_ files: [FileReference], generation: Int) {
        let items = files.enumerated().map { FilePreviewItem(id: $0.offset, file: $0.element) }
        content = .files(items)
        let checker = services.fileAvailability
        pendingLoad = Task { [weak self] in
            let availabilities = await FileAvailabilityProbe.check(files, with: checker)
            // Into the items shown now: they may have got thumbnails meanwhile (`update(to:)`).
            guard let self, self.generation == generation, !Task.isCancelled, case .files(var checked) = content
            else {
                return
            }
            for (index, availability) in zip(checked.indices, availabilities) {
                checked[index].availability = availability
            }
            content = .files(checked)
        }
    }
}
