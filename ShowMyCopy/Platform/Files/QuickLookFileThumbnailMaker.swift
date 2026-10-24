import CoreGraphics
import Darwin
import Foundation
import ImageIO
import QuickLookThumbnailing
import Synchronization
import UniformTypeIdentifiers

/// Makes thumbnails of copied photo and video files with QuickLook, which draws a frame of a video, and encodes them
/// as PNG.
///
/// The app is sandboxed: it can read a copied file only because reading its URL from the pasteboard gave it access
/// for as long as the app runs. QuickLook reads the file with that access in a system process (or a third-party
/// Quick Look extension), outside the app's sandbox, and gives back a small image; nothing of the file is kept here.
/// So QuickLook is asked only about files the app has checked first:
///
/// - Files whose data is on this Mac: not iCloud and other cloud files that are not downloaded (including "dataless"
///   placeholders of file providers), and not files on network volumes. The app never asks for a file that is not
///   local.
/// - Types in `FileThumbnailPolicy`, matched exactly: the allowed image formats and QuickTime and MPEG-4 movies. No
///   SVG, PDF or other format that can load external resources.
/// - An image file must start with the signature of its type, ImageIO must read it as that type, and its header
///   must be within `ImageDecodingPolicy.maximumPixelCount`. Only the header is read, in this process.
/// - A movie file must hold its own media (`MovieContainer`): no reference movies. Only box headers are read.
struct QuickLookFileThumbnailMaker: FileThumbnailMaking {
    private static let resourceKeys: Set<URLResourceKey> = [
        .contentTypeKey, .isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        .volumeIsLocalKey, .fileSizeKey,
    ]

    /// `SF_DATALESS` from <sys/stat.h>: the file's data lives with a file provider and reading it downloads it.
    private static let datalessFlag: UInt32 = 0x4000_0000

    /// How many bytes of an image file are read to check its signature.
    private static let signatureLength = 32

    func mediaKind(of url: URL) -> FileThumbnail.Kind? {
        guard url.isFileURL else {
            return nil
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Self.resourceKeys)
        } catch {
            // The file is gone or the sandbox hides it: it keeps its icon. Normal, so not an error.
            AppLogger.clipboard.debug("Could not look at a copied file for its thumbnail")
            return nil
        }
        guard values.isRegularFile == true, values.volumeIsLocal != false, Self.isDownloaded(values),
            !Self.isDataless(url), let type = values.contentType,
            let candidate = FileThumbnailPolicy.candidate(forContentType: type.identifier)
        else {
            return nil
        }
        switch candidate {
        case .image(let format):
            return Self.isAllowedImage(at: url, format: format) ? .image : nil
        case .movie:
            return Self.holdsItsOwnMedia(url, fileSize: values.fileSize) ? .movie : nil
        }
    }

    func thumbnail(of url: URL, maximumPixelSize: Int) async -> ImageInspection.Thumbnail? {
        let side = CGFloat(maximumPixelSize)
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: 1, representationTypes: .thumbnail)
        let pending = PendingThumbnail(request: request, maximumPixelSize: maximumPixelSize)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.start(continuation)
            }
        } onCancel: {
            pending.cancel()
        }
    }

    /// Not an iCloud (or other ubiquitous) item, or one whose data is on this Mac.
    private static func isDownloaded(_ values: URLResourceValues) -> Bool {
        guard values.isUbiquitousItem == true else {
            return true
        }
        let status = values.ubiquitousItemDownloadingStatus
        return status == .current || status == .downloaded
    }

    /// Whether the file is a placeholder whose data a file provider downloads when it is read. A file that cannot
    /// be looked at counts as one, so it is skipped. `stat` reads the metadata only and downloads nothing.
    private static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else {
            return true
        }
        return info.st_flags & datalessFlag != 0
    }

    /// Whether the image file starts with the signature of `format`, ImageIO reads it as that format, and its header
    /// is within the pixel limit. QuickLook would otherwise decode a decompression bomb, or hand a file to a decoder
    /// for another format than its name says.
    private static func isAllowedImage(at url: URL, format: ImageFormat) -> Bool {
        guard let start = read(url, offset: 0, count: signatureLength), ImageFormat(sniffing: start) == format,
            let image = CheckedImageSource.open(fileAt: url, format: format)
        else {
            AppLogger.clipboard.info("Skipped the thumbnail of an image file that is not the format its type says")
            return false
        }
        guard image.isWithinPixelLimit else {
            AppLogger.clipboard.info("Skipped the thumbnail of an image file over the pixel limit")
            return false
        }
        return true
    }

    /// Whether the movie file holds its own media, from its box headers. Not a reference movie, whose media
    /// QuickLook would have to load from elsewhere.
    private static func holdsItsOwnMedia(_ url: URL, fileSize: Int?) -> Bool {
        guard let fileSize, fileSize > 0 else {
            return false
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return false
        }
        defer {
            do {
                try handle.close()
            } catch {
                AppLogger.clipboard.debug("Could not close a copied movie file")
            }
        }
        let holds = MovieContainer.holdsItsOwnMedia(fileSize: UInt64(fileSize)) { offset, count in
            Self.read(handle, offset: offset, count: count)
        }
        if !holds {
            AppLogger.clipboard.info("Skipped the thumbnail of a movie file that does not hold its own media")
        }
        return holds
    }

    /// Up to `count` bytes of the file at `url` from `offset`, or nil when it cannot be read.
    private static func read(_ url: URL, offset: UInt64, count: Int) -> Data? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return nil
        }
        let data = read(handle, offset: offset, count: count)
        do {
            try handle.close()
        } catch {
            AppLogger.clipboard.debug("Could not close a copied image file")
        }
        return data
    }

    private static func read(_ handle: FileHandle, offset: UInt64, count: Int) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }

    /// `image` as PNG data, scaled down first if QuickLook gave a larger one.
    static func encode(_ image: CGImage, maximumPixelSize: Int) -> ImageInspection.Thumbnail? {
        guard let fitted = fitted(image, maximumPixelSize: maximumPixelSize) else {
            AppLogger.clipboard.error("Could not scale a file thumbnail")
            return nil
        }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, ThumbnailReference.typeIdentifier as CFString, 1, nil)
        else {
            AppLogger.clipboard.error("Could not encode a file thumbnail")
            return nil
        }
        CGImageDestinationAddImage(destination, fitted, nil)
        guard CGImageDestinationFinalize(destination) else {
            AppLogger.clipboard.error("Could not encode a file thumbnail")
            return nil
        }
        return ImageInspection.Thumbnail(pngData: output as Data, pixelWidth: fitted.width, pixelHeight: fitted.height)
    }

    private static func fitted(_ image: CGImage, maximumPixelSize: Int) -> CGImage? {
        let longer = max(image.width, image.height)
        guard longer > maximumPixelSize else {
            return image
        }
        let scale = Double(maximumPixelSize) / Double(longer)
        let width = max(1, min(maximumPixelSize, Int((Double(image.width) * scale).rounded())))
        let height = max(1, min(maximumPixelSize, Int((Double(image.height) * scale).rounded())))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// One QuickLook request, finished exactly once: by QuickLook's answer or by cancelling it, whichever comes first.
/// Cancelling returns at once, so a timeout never waits for QuickLook.
///
/// `@unchecked Sendable`: the request is set once and only handed to `QLThumbnailGenerator`, which may be called
/// from any thread; everything that changes is behind the mutex.
private final class PendingThumbnail: @unchecked Sendable {
    private enum State {
        case notStarted
        case waiting(CheckedContinuation<ImageInspection.Thumbnail?, Never>)
        case finished
    }

    private let request: QLThumbnailGenerator.Request
    private let maximumPixelSize: Int
    private let state = Mutex<State>(.notStarted)

    init(request: QLThumbnailGenerator.Request, maximumPixelSize: Int) {
        self.request = request
        self.maximumPixelSize = maximumPixelSize
    }

    func start(_ continuation: CheckedContinuation<ImageInspection.Thumbnail?, Never>) {
        let alreadyCancelled = state.withLock { state in
            guard case .notStarted = state else {
                return true
            }
            state = .waiting(continuation)
            return false
        }
        guard !alreadyCancelled else {
            continuation.resume(returning: nil)
            return
        }
        let maximumPixelSize = maximumPixelSize
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [self] representation, _ in
            guard let representation else {
                // The error says why, possibly with the file's name, so it is not logged.
                AppLogger.clipboard.debug("QuickLook made no thumbnail for a copied file")
                finish(with: nil)
                return
            }
            finish(with: QuickLookFileThumbnailMaker.encode(representation.cgImage, maximumPixelSize: maximumPixelSize))
        }
    }

    func cancel() {
        QLThumbnailGenerator.shared.cancel(request)
        finish(with: nil)
    }

    private func finish(with thumbnail: ImageInspection.Thumbnail?) {
        let waiting = state.withLock { state -> CheckedContinuation<ImageInspection.Thumbnail?, Never>? in
            defer { state = .finished }
            switch state {
            case .waiting(let continuation):
                return continuation
            case .notStarted, .finished:
                return nil
            }
        }
        waiting?.resume(returning: thumbnail)
    }
}
