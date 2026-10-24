import Foundation

/// A copied image. The bytes are not kept in memory: they are in a `BlobStore` under `blobID`, exactly as they were
/// on the pasteboard, and are read only when the image is shown in full or copied back. Everything a history row
/// needs (size, type, a small thumbnail) is here or in the thumbnail blob.
struct ImageReference: Equatable, Sendable {
    /// The original image data, in the format `typeIdentifier` names.
    let blobID: BlobID
    /// The Uniform Type Identifier of the data, one of `ImageReference.supportedTypes`, such as "public.png".
    let typeIdentifier: String
    let pixelWidth: Int
    let pixelHeight: Int
    /// The size of the image data in bytes.
    let byteSize: Int
    /// The digest of the image data, computed when it was copied. Identifies the image: copying the same bytes
    /// again finds the entry that already holds them.
    let contentHash: ContentHash
    /// A small PNG version for lists, or nil when none could be made.
    let thumbnail: ThumbnailReference?

    /// Image types the history keeps, in the order they are preferred when an item offers several: compressed
    /// formats first, TIFF (usually uncompressed and large) last.
    static let supportedTypes = ["public.png", "public.jpeg", "public.heic", "public.tiff"]

    /// The blobs the image takes: its data and its thumbnail.
    var blobIDs: [BlobID] {
        [blobID] + (thumbnail.map { [$0.blobID] } ?? [])
    }

    /// The bytes the image takes in the blob store, thumbnail included.
    var storedBytes: Int {
        byteSize + (thumbnail?.byteSize ?? 0)
    }

    /// A short name of the format for lists, such as "PNG".
    var formatName: String {
        switch typeIdentifier {
        case "public.png":
            "PNG"
        case "public.jpeg":
            "JPEG"
        case "public.heic":
            "HEIC"
        case "public.tiff":
            "TIFF"
        default:
            (typeIdentifier.split(separator: ".").last.map(String.init) ?? typeIdentifier).uppercased()
        }
    }
}

/// A thumbnail of an image: PNG data at most `ThumbnailReference.maximumPixelSize` pixels on its longer side, kept
/// in the blob store next to the image. Thumbnails are small (tens of kilobytes), so a list can read many of them;
/// the full image is read only when it is opened.
struct ThumbnailReference: Equatable, Sendable {
    static let maximumPixelSize = 256
    /// The type of every thumbnail.
    static let typeIdentifier = "public.png"

    let blobID: BlobID
    let pixelWidth: Int
    let pixelHeight: Int
    let byteSize: Int
}
