import Foundation

/// What `ThumbnailMaking` learned about image data.
struct ImageInspection: Equatable, Sendable {
    struct Thumbnail: Equatable, Sendable {
        /// PNG data.
        let pngData: Data
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// The image's size as it is shown, after its orientation is applied.
    let pixelWidth: Int
    let pixelHeight: Int
    /// Nil when the image could be measured but no thumbnail could be drawn.
    let thumbnail: Thumbnail?
}

enum ThumbnailError: Error, Equatable, Sendable {
    /// The data is not an image the system can read.
    case notAnImage
}

/// Measures copied image data and draws a small PNG thumbnail of it. The app uses ImageIO
/// (`ImageIOThumbnailMaker`, macOS only), which decodes only as much of the image as the thumbnail needs.
protocol ThumbnailMaking: Sendable {
    /// The image's size and a thumbnail at most `maximumPixelSize` pixels on its longer side (never larger than
    /// the image). Throws `notAnImage` when the data cannot be read as an image.
    func inspect(_ data: Data, maximumPixelSize: Int) throws(ThumbnailError) -> ImageInspection
}
