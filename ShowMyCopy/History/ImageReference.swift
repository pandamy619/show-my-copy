import Foundation

/// A copied image. The bytes are not kept in memory: they are in a `BlobStore` under `blobID`, exactly as they were
/// on the pasteboard, and are read only when the image is shown in full or copied back. Everything a history row
/// needs (size, type, a small thumbnail) is here or in the thumbnail blob.
///
/// A copy is recorded at once, before its data is saved (`unsaved(blobID:typeIdentifier:byteSize:)`), and completed
/// when `ImageIngestor` is done (`HistoryStore.completeImage`). Until then the image's bytes are held in memory by
/// the work that saves them, and `InFlightBlobStore` reads them from there, so the entry can be copied back or
/// previewed meanwhile.
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
    /// False from the copy until the data is saved and measured. Meanwhile the image has no thumbnail, its pixel
    /// size is 0 × 0, and `contentHash` is a stand-in no other image has, so the copy is never taken for another
    /// one before its data is known. Such an image is kept in memory only, never saved with the history.
    let isSaved: Bool

    init(
        blobID: BlobID,
        typeIdentifier: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteSize: Int,
        contentHash: ContentHash,
        thumbnail: ThumbnailReference?
    ) {
        self.init(
            blobID: blobID, typeIdentifier: typeIdentifier, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            byteSize: byteSize, contentHash: contentHash, thumbnail: thumbnail, isSaved: true)
    }

    private init(
        blobID: BlobID,
        typeIdentifier: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteSize: Int,
        contentHash: ContentHash,
        thumbnail: ThumbnailReference?,
        isSaved: Bool
    ) {
        self.blobID = blobID
        self.typeIdentifier = typeIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteSize = byteSize
        self.contentHash = contentHash
        self.thumbnail = thumbnail
        self.isSaved = isSaved
    }

    /// A copied image whose data will be saved under `blobID`, as it is recorded before that.
    static func unsaved(blobID: BlobID, typeIdentifier: String, byteSize: Int) -> ImageReference {
        // Not a digest: a zero byte and the blob ID, 17 bytes, which no SHA-256 digest of 32 bytes can equal.
        let standIn = ContentHash(bytes: [0] + withUnsafeBytes(of: blobID.uuid.uuid) { Array($0) })
        return ImageReference(
            blobID: blobID, typeIdentifier: typeIdentifier, pixelWidth: 0, pixelHeight: 0, byteSize: byteSize,
            contentHash: standIn, thumbnail: nil, isSaved: false)
    }

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
