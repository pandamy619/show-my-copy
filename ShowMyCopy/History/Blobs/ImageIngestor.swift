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
    /// The image could not be written to the blob store. What was written is given back by the reservation.
    case storageFailed
}

/// Turns copied image data into an `ImageReference`: hashes the bytes, measures the image, draws its thumbnail and
/// writes both to the blob store. The slow part of recording an image, so it runs off the main actor.
///
/// It writes only through the reservation it is given (see `InFlightBlobStore`): what it writes is held until the
/// caller has handed it to the history, and the caller deletes what no entry took.
struct ImageIngestor: Sendable {
    let thumbnails: any ThumbnailMaking
    let hasher: any ContentHasher

    init(thumbnails: any ThumbnailMaking, hasher: any ContentHasher = SHA256ContentHasher()) {
        self.thumbnails = thumbnails
        self.hasher = hasher
    }

    /// Stores `image` off the main actor, its data under `blobID` (reserved in `reservation`) and its thumbnail
    /// under a new ID. `known` holds the images already in the history by the digest of their data: copying one of
    /// them again writes nothing and gives back its reference, so the caller holds their blobs in `reservation`.
    @concurrent
    func ingest(
        _ image: CapturedImage,
        as blobID: BlobID,
        known: [ContentHash: ImageReference],
        reservation: BlobReservation
    ) async throws(ImageIngestError) -> IngestedImage {
        let contentHash = hasher.digest(of: image.data)
        if let existing = known[contentHash] {
            return IngestedImage(reference: existing, isNew: false)
        }
        let inspection: ImageInspection
        do {
            inspection = try await thumbnails.inspect(
                image.data, declaredType: image.typeIdentifier, maximumPixelSize: ThumbnailReference.maximumPixelSize)
        } catch {
            AppLogger.clipboard.info("Skipped image data that could not be read as an image")
            throw .notAnImage
        }
        var thumbnail: ThumbnailReference?
        do {
            try reservation.write(image.data, as: blobID)
            if let made = inspection.thumbnail {
                thumbnail = ThumbnailReference(
                    blobID: try reservation.write(made.pngData), pixelWidth: made.pixelWidth,
                    pixelHeight: made.pixelHeight, byteSize: made.pngData.count)
            }
        } catch {
            throw .storageFailed
        }
        let reference = ImageReference(
            blobID: blobID, typeIdentifier: image.typeIdentifier, pixelWidth: inspection.pixelWidth,
            pixelHeight: inspection.pixelHeight, byteSize: image.data.count, contentHash: contentHash,
            thumbnail: thumbnail)
        return IngestedImage(reference: reference, isNew: true)
    }
}
