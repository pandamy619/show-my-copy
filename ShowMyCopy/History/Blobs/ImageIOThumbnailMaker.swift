import CoreGraphics
import Foundation
import ImageIO

/// Measures images and draws thumbnails with ImageIO.
///
/// The data is opened through `CheckedImageSource`: it must be an allowed format, the one it was copied as, before
/// ImageIO parses more than its first bytes. The size comes from the image's header. An image over
/// `ImageDecodingPolicy.maximumPixelCount` is measured but not decoded, so it is recorded without a thumbnail.
/// Otherwise the thumbnail is made with `kCGImageSourceThumbnailMaxPixelSize`, so ImageIO decodes at a reduced size
/// (or uses a thumbnail embedded in the file) instead of the whole image, and nothing is cached: the full image is
/// never kept in memory here.
struct ImageIOThumbnailMaker: ImageThumbnailMaking {
    func inspect(_ data: Data, declaredType: String, maximumPixelSize: Int) throws(ThumbnailError) -> ImageInspection {
        guard let image = CheckedImageSource.open(data, declaredType: declaredType) else {
            throw .notAnImage
        }
        // EXIF orientations 5 to 8 turn the image by 90 degrees, so it is shown with width and height swapped.
        let isTurned = (5...8).contains(image.orientation)
        let thumbnail: ImageInspection.Thumbnail?
        if image.isWithinPixelLimit {
            thumbnail = self.thumbnail(of: image.source, maximumPixelSize: maximumPixelSize)
        } else {
            AppLogger.clipboard.info("Recorded an image over the pixel limit without decoding it")
            thumbnail = nil
        }
        return ImageInspection(
            pixelWidth: isTurned ? image.pixelHeight : image.pixelWidth,
            pixelHeight: isTurned ? image.pixelWidth : image.pixelHeight,
            thumbnail: thumbnail
        )
    }

    private func thumbnail(of source: CGImageSource, maximumPixelSize: Int) -> ImageInspection.Thumbnail? {
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: false,
            ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            AppLogger.clipboard.error("Could not draw a thumbnail of an image")
            return nil
        }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, ThumbnailReference.typeIdentifier as CFString, 1, nil)
        else {
            AppLogger.clipboard.error("Could not encode a thumbnail")
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            AppLogger.clipboard.error("Could not encode a thumbnail")
            return nil
        }
        return ImageInspection.Thumbnail(pngData: output as Data, pixelWidth: image.width, pixelHeight: image.height)
    }
}
