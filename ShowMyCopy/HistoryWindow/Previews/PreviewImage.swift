import Foundation

/// A decoded image, ready to draw. Platform code makes it (`ImageIOPreviewDecoder` on macOS); the history window
/// only keeps it, counts its size and hands it to the view.
protocol PreviewImage: Sendable {
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }
}

extension PreviewImage {
    /// About how much memory the decoded pixels take: four bytes a pixel. Caches count this, not the file size.
    var decodedByteCount: Int {
        let (pixels, pixelsOverflow) = max(pixelWidth, 0).multipliedReportingOverflow(by: max(pixelHeight, 0))
        let (bytes, bytesOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return pixelsOverflow || bytesOverflow ? Int.max : bytes
    }
}

/// Decodes image data for the history window. Called off the main actor.
protocol PreviewImageDecoding: Sendable {
    /// The image in `data`, scaled down so its longer side is at most `maximumPixelSize` pixels (never scaled up),
    /// or nil when the data is not an image the system can read or fails `ImageDecodingPolicy` (a format that is
    /// not allowed, or more pixels than it allows).
    func decode(_ data: Data, maximumPixelSize: Int) -> (any PreviewImage)?
}

/// Where a preview stands: still loading, ready, or failed (the view then shows a placeholder).
enum PreviewLoadState<Value: Sendable>: Sendable {
    case loading
    case loaded(Value)
    case failed

    var value: Value? {
        if case .loaded(let value) = self {
            return value
        }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }

    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

/// Reads an image blob and decodes it off the main actor. Errors are logged without the data; the caller shows a
/// placeholder.
enum PreviewImageLoader {
    @concurrent
    static func load(
        _ id: BlobID,
        from blobs: any BlobStore,
        decoder: any PreviewImageDecoding,
        maximumPixelSize: Int
    ) async -> (any PreviewImage)? {
        let data: Data
        do {
            data = try blobs.read(id)
        } catch {
            // The error is a case name without data or file names.
            AppLogger.history.error(
                "Could not read image data for a preview: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard !Task.isCancelled else {
            return nil
        }
        guard let image = decoder.decode(data, maximumPixelSize: maximumPixelSize) else {
            AppLogger.history.error("Could not decode image data for a preview")
            return nil
        }
        return image
    }
}
