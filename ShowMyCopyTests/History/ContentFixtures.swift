import Foundation

@testable import ShowMyCopy

/// Content of the kinds other than plain text, for tests.
enum ContentFixtures {
    static let rtf = Data(#"{\rtf1\ansi {\b Bold} text}"#.utf8)

    static func richText(_ plain: String = "Bold text", rtf: Data = ContentFixtures.rtf) -> ClipboardContent {
        .richText(rtf: rtf, plain: plain)
    }

    /// An image reference with made-up blob IDs. `hashByte` makes the image's own digest, so equal bytes stand for
    /// the same image.
    static func imageReference(
        hashByte: UInt8 = 1,
        byteSize: Int = 1000,
        thumbnailBytes: Int? = 100,
        blobID: BlobID = BlobID(),
        thumbnailID: BlobID = BlobID()
    ) -> ImageReference {
        ImageReference(
            blobID: blobID,
            typeIdentifier: "public.png",
            pixelWidth: 640,
            pixelHeight: 480,
            byteSize: byteSize,
            contentHash: ContentHash(bytes: [UInt8](repeating: hashByte, count: 32)),
            thumbnail: thumbnailBytes.map {
                ThumbnailReference(blobID: thumbnailID, pixelWidth: 256, pixelHeight: 192, byteSize: $0)
            }
        )
    }

    static func image(hashByte: UInt8 = 1, byteSize: Int = 1000, thumbnailBytes: Int? = 100) -> ClipboardContent {
        .image(imageReference(hashByte: hashByte, byteSize: byteSize, thumbnailBytes: thumbnailBytes))
    }

    /// An image whose data and thumbnail are written to `blobs`, as `ImageIngestor` stores a copied image.
    static func storedImage(
        in blobs: any BlobStore,
        bytes: Data = Data(repeating: 7, count: 1000),
        thumbnail: Data = Data(repeating: 8, count: 100),
        hasher: any ContentHasher = SHA256ContentHasher()
    ) throws -> ImageReference {
        let blobID = try blobs.write(bytes)
        let thumbnailID = try blobs.write(thumbnail)
        return ImageReference(
            blobID: blobID,
            typeIdentifier: "public.png",
            pixelWidth: 640,
            pixelHeight: 480,
            byteSize: bytes.count,
            contentHash: hasher.digest(of: bytes),
            thumbnail: ThumbnailReference(
                blobID: thumbnailID, pixelWidth: 256, pixelHeight: 192, byteSize: thumbnail.count)
        )
    }

    static func file(_ path: String, byteSize: Int? = 42) -> FileReference {
        FileReference(url: URL(filePath: path), byteSize: byteSize)
    }

    static func files(_ paths: String...) -> ClipboardContent {
        .files(paths.map { file($0) })
    }
}
