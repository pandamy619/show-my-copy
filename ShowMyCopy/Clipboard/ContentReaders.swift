import AppKit

/// Image data as it was on the pasteboard, not yet stored. `ImageIngestor` hashes it, makes a thumbnail and writes
/// it to the blob store off the main actor; until then it is the only copy in the app.
struct CapturedImage: Equatable, Sendable {
    let data: Data
    /// The Uniform Type Identifier the data was read as, one of `ImageReference.supportedTypes`.
    let typeIdentifier: String
}

extension PasteboardSnapshotReader {
    /// The readers the app uses, in the order they are tried:
    ///
    /// 1. Files. Finder puts the file names as text and an icon next to the file URLs.
    /// 2. Images, when `readsImages` (only when there is somewhere to store them). An item that also holds text is
    ///    left to the text readers: Word, Excel, Pages and others put a picture of the copied text next to it.
    /// 3. Rich text (RTF with its plain text).
    /// 4. Plain text.
    static func standardReaders(readsImages: Bool) -> [any PasteboardContentReader] {
        var readers: [any PasteboardContentReader] = [FileURLContentReader()]
        if readsImages {
            readers.append(ImageContentReader())
        }
        readers.append(RichTextContentReader())
        readers.append(TextContentReader())
        return readers
    }
}

/// Reads copied files: their URLs and names, never their contents. Nothing here touches the files: their sizes are
/// read later, off the main actor (`FileSizeReader`), since even that can wait for a slow disk or a server.
struct FileURLContentReader: PasteboardContentReader {
    nonisolated static let defaultMaximumCount = 100

    /// The most files kept from one copy. More are skipped without reading any URL.
    let maximumCount: Int

    init(maximumCount: Int = FileURLContentReader.defaultMaximumCount) {
        self.maximumCount = maximumCount
    }

    func read(from pasteboard: any PasteboardReading) -> ContentReading {
        guard pasteboard.types.contains(.fileURL) else {
            return .nothing
        }
        // Each file is an item of its own, so the count is known before any URL is read.
        guard pasteboard.itemCount <= maximumCount else {
            return .tooLarge(limit: maximumCount)
        }
        let urls = pasteboard.fileURLs().filter(\.isFileURL)
        guard !urls.isEmpty else {
            return .nothing
        }
        guard urls.count <= maximumCount else {
            return .tooLarge(limit: maximumCount)
        }
        return .content(.files(urls.map { FileReference(url: $0) }))
    }
}

/// Reads a copied image as the bytes it was copied in, without decoding it.
struct ImageContentReader: PasteboardContentReader {
    nonisolated static let defaultMaximumBytes = 20 * 1_048_576

    /// The largest image data kept, in bytes, checked on the data's length before anything is made of it.
    let maximumBytes: Int

    init(maximumBytes: Int = ImageContentReader.defaultMaximumBytes) {
        self.maximumBytes = maximumBytes
    }

    func read(from pasteboard: any PasteboardReading) -> ContentReading {
        let types = Set(pasteboard.types)
        guard types.isDisjoint(with: PasteboardSnapshotReader.textTypes) else {
            return .nothing
        }
        let supported = ImageReference.supportedTypes.map { NSPasteboard.PasteboardType($0) }
        guard let type = supported.first(where: types.contains),
            let data = pasteboard.data(forType: type), !data.isEmpty
        else {
            return .nothing
        }
        guard data.count <= maximumBytes else {
            return .tooLarge(limit: maximumBytes)
        }
        return .image(CapturedImage(data: data, typeIdentifier: type.rawValue))
    }
}

/// Reads styled text: the RTF data and the plain text that comes with it.
///
/// The plain text is read first. It is never larger than the RTF it comes with, so styled text whose plain text is
/// over its limit is skipped without reading the RTF at all (see `PasteboardSnapshotReader` on why sizes are known
/// only after reading). RTF over its own limit is kept as the plain text already read.
struct RichTextContentReader: PasteboardContentReader {
    nonisolated static let defaultMaximumBytes = 1_048_576

    /// The largest RTF data kept, in bytes. Styled text over it is kept as plain text.
    let maximumBytes: Int
    private let text: TextContentReader

    init(
        maximumBytes: Int = RichTextContentReader.defaultMaximumBytes,
        textLimit: Int = TextContentReader.defaultMaximumBytes
    ) {
        self.maximumBytes = maximumBytes
        self.text = TextContentReader(maximumBytes: textLimit)
    }

    func read(from pasteboard: any PasteboardReading) -> ContentReading {
        guard pasteboard.types.contains(.rtf) else {
            return .nothing
        }
        let plain: String
        switch text.read(from: pasteboard) {
        case .content(.text(let found)):
            plain = found
        case .content, .image, .nothing:
            // Without plain text the history could not show or search it.
            return .nothing
        case .tooLarge(let limit):
            return .tooLarge(limit: limit)
        }
        guard let rtf = pasteboard.data(forType: .rtf), !rtf.isEmpty else {
            return .nothing
        }
        guard rtf.count <= maximumBytes else {
            AppLogger.clipboard.debug("Styled text over the size limit is kept as plain text")
            return .content(.text(plain))
        }
        return .content(.richText(rtf: rtf, plain: plain))
    }
}
