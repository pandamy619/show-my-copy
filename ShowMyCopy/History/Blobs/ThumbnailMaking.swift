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
    /// Nil when the image could be measured but no thumbnail could be drawn, or it has more pixels than
    /// `ImageDecodingPolicy.maximumPixelCount` and so was not decoded.
    let thumbnail: Thumbnail?
}

enum ThumbnailError: Error, Equatable, Sendable {
    /// The data is not an image the system can read, not an allowed format (`ImageDecodingPolicy`), or not the
    /// format it was copied as.
    case notAnImage
}

/// Measures copied image data and draws a small PNG thumbnail of it. The app uses ImageIO
/// (`ImageIOThumbnailMaker`, macOS only), which decodes only as much of the image as the thumbnail needs.
///
/// Called off the main actor while an image recorded already is saved (`ImageIngestor`). `async`, so a maker may
/// suspend instead of holding a thread; `ImageIOThumbnailMaker` does its work at once on the caller's thread.
protocol ThumbnailMaking: Sendable {
    /// The image's size and a thumbnail at most `maximumPixelSize` pixels on its longer side (never larger than
    /// the image). `declaredType` is the type the data was copied as. Throws `notAnImage` when the data cannot be
    /// read as an image or fails `ImageDecodingPolicy`. Only an image within the policy's pixel limit is decoded;
    /// a larger one is measured from its header and has no thumbnail.
    func inspect(
        _ data: Data, declaredType: String, maximumPixelSize: Int
    ) async throws(ThumbnailError) -> ImageInspection
}
