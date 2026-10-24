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

/// Reads copied files: their URLs, names and sizes, never their contents.
struct FileURLContentReader: PasteboardContentReader {
    nonisolated static let defaultMaximumCount = 100

    /// The most files kept from one copy. More are skipped without reading any URL.
    let maximumCount: Int
    private let fileSize: (URL) -> Int?

    init(
        maximumCount: Int = FileURLContentReader.defaultMaximumCount,
        fileSize: @escaping (URL) -> Int? = { FileURLContentReader.sizeOfFile(at: $0) }
    ) {
        self.maximumCount = maximumCount
        self.fileSize = fileSize
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
        return .content(.files(urls.map { FileReference(url: $0, byteSize: fileSize($0)) }))
    }

    /// The size of a regular file, or nil for a folder, a missing file or one the sandbox does not let the app see.
    /// Not knowing the size is normal in the sandbox, so it is not logged.
    nonisolated static func sizeOfFile(at url: URL) -> Int? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        } catch {
            return nil
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.intValue
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
struct RichTextContentReader: PasteboardContentReader {
    nonisolated static let defaultMaximumBytes = 1_048_576

    /// The largest RTF data kept, in bytes. Styled text over it is kept as plain text by the text reader.
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
        guard pasteboard.types.contains(.rtf), let rtf = pasteboard.data(forType: .rtf), !rtf.isEmpty else {
            return .nothing
        }
        guard rtf.count <= maximumBytes else {
            AppLogger.clipboard.debug("Styled text over the size limit is kept as plain text")
            return .nothing
        }
        switch text.read(from: pasteboard) {
        case .content(.text(let plain)):
            return .content(.richText(rtf: rtf, plain: plain))
        case .content, .image, .nothing:
            // Without plain text the history could not show or search it.
            return .nothing
        case .tooLarge(let limit):
            return .tooLarge(limit: limit)
        }
    }
}
