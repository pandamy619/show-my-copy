import Foundation

/// What was copied, independent of where the history keeps it.
///
/// Switch over this type without a `default` case, so the compiler lists every place that has to handle a new kind.
enum ClipboardContent: Equatable, Sendable {
    case text(String)
    /// Styled text: the RTF data as it was copied, and its plain text for search, previews and apps that paste
    /// plain text only.
    case richText(rtf: Data, plain: String)
    /// An image whose bytes are kept in a `BlobStore`.
    case image(ImageReference)
    /// One or more files or folders, by location only.
    case files([FileReference])

    /// The kind of content, for filters, icons and storage. One case per case of `ClipboardContent`. The raw
    /// values are saved with the history, so never change them.
    enum Kind: String, CaseIterable, Sendable {
        case text
        case richText
        case image
        case files
    }

    var kind: Kind {
        switch self {
        case .text:
            .text
        case .richText:
            .richText
        case .image:
            .image
        case .files:
            .files
        }
    }

    /// The plain text, or nil for content that has none. Rich text gives its plain text.
    var text: String? {
        switch self {
        case .text(let text):
            text
        case .richText(_, let plain):
            plain
        case .image, .files:
            nil
        }
    }

    /// What search looks in: the plain text, or the names of copied files. Nil for an image.
    var searchableText: String? {
        switch self {
        case .text, .richText, .image:
            text
        case .files(let files):
            files.map(\.name).joined(separator: "\n")
        }
    }

    /// The size of the content's data in bytes, for size limits and statistics: the UTF-8 length for text, the
    /// RTF data and its plain text for rich text, the image data and its thumbnail in the blob store for an image,
    /// and the stored paths, names and thumbnails for files (not the files themselves, which the history does not
    /// keep).
    var byteSize: Int {
        switch self {
        case .text(let text):
            text.utf8.count
        case .richText(let rtf, let plain):
            rtf.count + plain.utf8.count
        case .image(let image):
            image.storedBytes
        case .files(let files):
            files.reduce(0) {
                $0 + $1.path.utf8.count + $1.name.utf8.count + ($1.thumbnail?.reference.byteSize ?? 0)
            }
        }
    }

    /// The blobs the content keeps in a `BlobStore`: an image's data and thumbnail, the thumbnails of copied photos
    /// and videos. Whoever removes the content deletes them.
    var blobIDs: [BlobID] {
        switch self {
        case .text, .richText:
            []
        case .image(let image):
            image.blobIDs
        case .files(let files):
            files.compactMap(\.thumbnail?.blobID)
        }
    }

    /// The content with the blobs that are gone dropped, or nil when it cannot do without them. An image is
    /// nothing without its data, and its record has always been deleted when any of its blobs was gone. A file
    /// entry only loses the thumbnails: the files are still worth keeping.
    func droppingBlobs(_ missing: Set<BlobID>) -> ClipboardContent? {
        guard !missing.isEmpty else {
            return self
        }
        switch self {
        case .text, .richText:
            return self
        case .image(let image):
            return image.blobIDs.contains(where: missing.contains) ? nil : self
        case .files(let files):
            return .files(
                files.map { file in
                    file.thumbnail.map { missing.contains($0.blobID) } == true ? file.withThumbnail(nil) : file
                })
        }
    }

    /// For the same files copied again, or their thumbnails and sizes read later: this content with the thumbnails and
    /// sizes it lacks taken from `newer`, file by file. Those it has stay, so a thumbnail that already belongs to the
    /// entry is never replaced. Other kinds, and files whose paths differ, are returned unchanged.
    func addingMissingFileDetails(from newer: ClipboardContent) -> ClipboardContent {
        guard case .files(let files) = self, case .files(let newFiles) = newer, files.count == newFiles.count,
            zip(files, newFiles).allSatisfy({ $0.path == $1.path })
        else {
            return self
        }
        return .files(
            zip(files, newFiles).map { old, new in
                let filled = old.thumbnail == nil ? old.withThumbnail(new.thumbnail) : old
                return filled.byteSize == nil ? filled.withByteSize(new.byteSize) : filled
            })
    }

    /// The image, for content that is one.
    var image: ImageReference? {
        switch self {
        case .image(let image):
            image
        case .text, .richText, .files:
            nil
        }
    }

    /// Whether the content can be kept as a concealed entry (a password). Only text and rich text can: their data
    /// is sealed in the record. Image data lives in plain files and file entries name files, so a secret is never
    /// kept as either; such an entry is removed instead of concealed.
    var canBeConcealed: Bool {
        switch self {
        case .text, .richText:
            true
        case .image, .files:
            false
        }
    }

    /// The bytes the content hash is computed from: a tag for the kind, then the content's data.
    ///
    /// Text is normalized to NFC first, so text that Swift considers equal (such as "é" written as one or two
    /// scalars) gets the same hash, as it did when entries were compared by text. Hashes are kept with the history,
    /// so never change the encoding of an existing case: a new kind gets a new tag. Variable-length parts are
    /// prefixed with their length, so two different contents can never give the same bytes.
    var canonicalBytes: Data {
        switch self {
        case .text(let text):
            var data = Data([Self.textTag])
            data.append(contentsOf: text.precomposedStringWithCanonicalMapping.utf8)
            return data
        case .richText(let rtf, let plain):
            // The RTF bytes and the plain text: the same words with other styling are other content.
            var data = Data([Self.richTextTag])
            data.appendLengthPrefixed(rtf)
            data.append(contentsOf: plain.precomposedStringWithCanonicalMapping.utf8)
            return data
        case .image(let image):
            // The digest of the image data, not the blob ID: the same bytes copied again are the same image.
            var data = Data([Self.imageTag])
            data.append(contentsOf: image.contentHash.bytes)
            return data
        case .files(let files):
            // The paths in order. Names and sizes are not part of it: they follow from the path.
            var data = Data([Self.filesTag])
            for file in files {
                data.appendLengthPrefixed(Data(file.path.utf8))
            }
            return data
        }
    }

    private static let textTag: UInt8 = 0x01
    private static let richTextTag: UInt8 = 0x02
    private static let imageTag: UInt8 = 0x03
    private static let filesTag: UInt8 = 0x04
}

extension Data {
    /// Appends the length of `bytes` as 4 big-endian bytes, then `bytes`.
    mutating func appendLengthPrefixed(_ bytes: Data) {
        let length = UInt32(clamping: bytes.count)
        append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) })
        append(bytes)
    }
}
