import CoreGraphics
import Foundation
import ImageIO

/// An ImageIO source for image data or an image file that passed `ImageDecodingPolicy`: its bytes are an allowlisted
/// format, ImageIO reads them as that same format, and its header was read. No pixels are decoded here.
///
/// Every place that decodes untrusted images opens them through this, so the checks are the same everywhere. The
/// allowlist is checked per source rather than with `CGImageSourceSetAllowableTypes`, which would restrict ImageIO
/// for the whole process, including AppKit drawing the app's own images.
struct CheckedImageSource {
    let source: CGImageSource
    let format: ImageFormat
    /// The size in the header, before the orientation is applied.
    let pixelWidth: Int
    let pixelHeight: Int
    /// The EXIF orientation, 1 to 8.
    let orientation: Int

    /// Whether the header's size lets the image be decoded (`ImageDecodingPolicy.maximumPixelCount`).
    var isWithinPixelLimit: Bool {
        ImageDecodingPolicy.allowsDecoding(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    /// Opens image data that was copied as `declaredType`, or nil when the type is not known. Nil when the data
    /// fails the policy or has no readable header.
    static func open(_ data: Data, declaredType: String?) -> CheckedImageSource? {
        guard let format = ImageDecodingPolicy.format(of: data, declaredType: declaredType) else {
            AppLogger.clipboard.info("Skipped image data that is not an allowed format or not its declared type")
            return nil
        }
        return CheckedImageSource(CGImageSourceCreateWithData(data as CFData, options(for: format)), format: format)
    }

    /// Opens a local image file whose first bytes were already checked to be `format`. Nil when ImageIO reads it as
    /// another format or its header cannot be read. Only call this for a file on a local volume whose data is on
    /// this Mac: ImageIO reads it in this process.
    static func open(fileAt url: URL, format: ImageFormat) -> CheckedImageSource? {
        guard url.isFileURL else {
            return nil
        }
        return CheckedImageSource(CGImageSourceCreateWithURL(url as CFURL, options(for: format)), format: format)
    }

    /// No caching, and the format as a hint so ImageIO tries that reader first.
    private static func options(for format: ImageFormat) -> CFDictionary {
        [
            kCGImageSourceShouldCache: false,
            kCGImageSourceTypeIdentifierHint: format.typeIdentifier as CFString,
        ] as CFDictionary
    }

    private init?(_ source: CGImageSource?, format: ImageFormat) {
        guard let source else {
            return nil
        }
        // ImageIO detects the format from the bytes, whatever the hint says: it must be the one the bytes were
        // checked to be, or a RAW photo that starts like a TIFF would reach the RAW decoder.
        guard ImageDecodingPolicy.accepts(detectedType: CGImageSourceGetType(source) as String?, for: format) else {
            AppLogger.clipboard.info("Skipped image data that ImageIO reads as another format")
            return nil
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0
        else {
            return nil
        }
        self.source = source
        self.format = format
        pixelWidth = width
        pixelHeight = height
        orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }
}
