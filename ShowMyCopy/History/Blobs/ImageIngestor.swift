import Foundation
import os

/// An image after `ImageIngestor` stored it.
struct IngestedImage: Equatable, Sendable {
    let reference: ImageReference
    /// False when the same image data was already in the history and its reference is used again: nothing was
    /// written.
    let isNew: Bool
}

enum ImageIngestError: Error, Equatable, Sendable {
    /// The data could not be read as an image. Nothing was stored.
    case notAnImage
    /// The image could not be written to the blob store. Nothing was left behind, or what was is swept at the next
    /// launch.
    case storageFailed
}

/// Turns copied image data into an `ImageReference`: hashes the bytes, measures the image, draws its thumbnail and
/// writes both to the blob store. The slow part of recording an image, so it runs off the main actor.
struct ImageIngestor: Sendable {
    let blobs: any BlobStore
    let thumbnails: any ThumbnailMaking
    let hasher: any ContentHasher

    init(blobs: any BlobStore, thumbnails: any ThumbnailMaking, hasher: any ContentHasher = SHA256ContentHasher()) {
        self.blobs = blobs
        self.thumbnails = thumbnails
        self.hasher = hasher
    }

    /// Stores `image` off the main actor. `known` holds the images already in the history by the digest of their
    /// data: copying one of them again writes nothing and gives back its reference.
    @concurrent
    func ingest(
        _ image: CapturedImage,
        known: [ContentHash: ImageReference]
    ) async throws(ImageIngestError) -> IngestedImage {
        try store(image, known: known)
    }

    /// The work of `ingest`, on the caller's thread.
    func store(_ image: CapturedImage, known: [ContentHash: ImageReference]) throws(ImageIngestError) -> IngestedImage {
        let contentHash = hasher.digest(of: image.data)
        if let existing = known[contentHash] {
            return IngestedImage(reference: existing, isNew: false)
        }
        let inspection: ImageInspection
        do {
            inspection = try thumbnails.inspect(image.data, maximumPixelSize: ThumbnailReference.maximumPixelSize)
        } catch {
            AppLogger.clipboard.info("Skipped image data that could not be read as an image")
            throw .notAnImage
        }
        let blobID: BlobID
        do {
            blobID = try blobs.write(image.data)
        } catch {
            throw .storageFailed
        }
        var thumbnail: ThumbnailReference?
        if let made = inspection.thumbnail {
            do {
                thumbnail = ThumbnailReference(
                    blobID: try blobs.write(made.pngData), pixelWidth: made.pixelWidth, pixelHeight: made.pixelHeight,
                    byteSize: made.pngData.count)
            } catch {
                deleteBlobs([blobID])
                throw .storageFailed
            }
        }
        let reference = ImageReference(
            blobID: blobID, typeIdentifier: image.typeIdentifier, pixelWidth: inspection.pixelWidth,
            pixelHeight: inspection.pixelHeight, byteSize: image.data.count, contentHash: contentHash,
            thumbnail: thumbnail)
        return IngestedImage(reference: reference, isNew: true)
    }

    /// Deletes what `ingest` wrote for an image that is not recorded after all. A reused reference belongs to its
    /// entry and is left alone.
    func discard(_ image: IngestedImage) {
        guard image.isNew else {
            return
        }
        deleteBlobs(image.reference.blobIDs)
    }

    private func deleteBlobs(_ ids: [BlobID]) {
        do {
            try blobs.delete(ids)
        } catch {
            AppLogger.history.error("Could not delete image data that is not used; it goes at the next launch")
        }
    }
}
