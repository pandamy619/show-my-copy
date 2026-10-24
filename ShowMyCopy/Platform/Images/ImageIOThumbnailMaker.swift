import CoreGraphics
import Foundation
import ImageIO

/// Measures images and draws thumbnails with ImageIO.
///
/// The size comes from the image's header. The thumbnail is made with `kCGImageSourceThumbnailMaxPixelSize`, so
/// ImageIO decodes at a reduced size (or uses a thumbnail embedded in the file) instead of the whole image, and
/// nothing is cached: the full image is never kept in memory here.
struct ImageIOThumbnailMaker: ThumbnailMaking {
    func inspect(_ data: Data, maximumPixelSize: Int) throws(ThumbnailError) -> ImageInspection {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0
        else {
            throw .notAnImage
        }
        // EXIF orientations 5 to 8 turn the image by 90 degrees, so it is shown with width and height swapped.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let isTurned = (5...8).contains(orientation)
        return ImageInspection(
            pixelWidth: isTurned ? height : width,
            pixelHeight: isTurned ? width : height,
            thumbnail: thumbnail(of: source, maximumPixelSize: maximumPixelSize)
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
