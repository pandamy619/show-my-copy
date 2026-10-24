import CoreGraphics
import Foundation
import ImageIO

/// A decoded image for the history window.
///
/// `@unchecked Sendable`: a `CGImage` is immutable once made and Core Graphics documents it as safe to use from any
/// thread, so it can be decoded off the main actor and drawn on it.
struct CGPreviewImage: PreviewImage, @unchecked Sendable {
    let cgImage: CGImage

    var pixelWidth: Int {
        cgImage.width
    }

    var pixelHeight: Int {
        cgImage.height
    }
}

/// Decodes thumbnails and full images with ImageIO, at most at the size the history window draws them.
///
/// `kCGImageSourceThumbnailMaxPixelSize` makes ImageIO decode at a reduced size instead of decoding the whole image
/// and scaling it, so a 50-megapixel photo never takes its full size in memory. The pixels are decoded here
/// (`kCGImageSourceShouldCacheImmediately`), off the main actor, rather than when the image is first drawn.
struct ImageIOPreviewDecoder: PreviewImageDecoding {
    func decode(_ data: Data, maximumPixelSize: Int) -> (any PreviewImage)? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard maximumPixelSize > 0,
            let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
            CGImageSourceGetCount(source) > 0
        else {
            return nil
        }
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return CGPreviewImage(cgImage: image)
    }
}
