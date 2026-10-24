import Foundation
import Synchronization
import os

/// Gives copied photo and video files their thumbnails, while the app can still read them.
///
/// After a relaunch the sandbox no longer lets the app read a copied file, so its thumbnail is made right when it is
/// copied and kept in the blob store, like an image's thumbnail. Only the thumbnail is kept, never the file's data.
/// The work is bounded: only the first `Limits.maximumFiles` files of a copy are looked at (those without a
/// thumbnail), each gets at most `Limits.timeoutPerFile`, and all of them together `Limits.totalBudget`. The limits
/// also cover the synchronous checks of the file (`FileThumbnailMaking.mediaKind`), which cannot be cancelled: when the
/// time is up the copy goes on without waiting for them (`TimeLimit`). A file on a network volume or an automounted
/// path (`CopiedPaths`) is not touched at all. A file that is not a photo or video, cannot be read, is not on this Mac
/// or takes too long keeps its icon. Runs off the main actor, and writes only through the reservation it is given
/// (see `InFlightBlobStore`).
struct FileThumbnailIngestor: Sendable {
    struct Limits: Equatable, Sendable {
        /// How many files of one copy are looked at, from the first. Rows show the first file; the preview lists
        /// the rest with their icons.
        let maximumFiles: Int
        /// How long one thumbnail may take. QuickLook may have to read a large video from a slow disk.
        let timeoutPerFile: Duration
        /// How long all thumbnails of one copy may take. The files are recorded before and the thumbnails of the
        /// next copy wait for these, so this stays short.
        let totalBudget: Duration

        static let standard = Limits(
            maximumFiles: 4, timeoutPerFile: .milliseconds(1500), totalBudget: .seconds(2))
    }

    let maker: any FileThumbnailMaking
    let limits: Limits
    /// Which files may be looked at.
    let paths: CopiedPaths
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        maker: any FileThumbnailMaking,
        limits: Limits = .standard,
        paths: CopiedPaths = CopiedPaths(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.maker = maker
        self.limits = limits
        self.paths = paths
        self.sleep = sleep
    }

    /// `files` in the same order, each with the thumbnail made now or none: thumbnails for the photos and videos
    /// among the first `limits.maximumFiles` that have none yet. A thumbnail a file already had is not returned, so
    /// handing the result on or deleting what is left never touches it. The new thumbnails are written through
    /// `reservation`, which the caller releases after handing them to a history store.
    @concurrent
    func ingest(_ files: [FileReference], reservation: BlobReservation) async -> [FileReference] {
        let made = await makeThumbnails(for: files)
        var result = files.map { $0.withThumbnail(nil) }
        for (index, thumbnail) in made.sorted(by: { $0.key < $1.key }) {
            let id: BlobID
            do {
                id = try reservation.write(thumbnail.image.pngData)
            } catch {
                // Logged by the blob store; the file keeps its icon.
                continue
            }
            let reference = ThumbnailReference(
                blobID: id, pixelWidth: thumbnail.image.pixelWidth, pixelHeight: thumbnail.image.pixelHeight,
                byteSize: thumbnail.image.pngData.count)
            result[index] = result[index].withThumbnail(FileThumbnail(kind: thumbnail.kind, reference: reference))
        }
        return result
    }

    private struct Made: Sendable {
        let kind: FileThumbnail.Kind
        let image: ImageInspection.Thumbnail
    }

    /// The thumbnails made in time, by the file's position. One file at a time, so a copy of many videos does not
    /// start many QuickLook requests at once.
    private func makeThumbnails(for files: [FileReference]) async -> [Int: Made] {
        // Only local files: QuickLook is never asked for anything that could be fetched over the network, and
        // nothing on a network volume is even looked up.
        let paths = paths
        let candidates = files.prefix(max(limits.maximumFiles, 0)).enumerated().filter {
            $0.element.thumbnail == nil && paths.access(for: $0.element.url) != .remote
        }
        guard !candidates.isEmpty else {
            return [:]
        }
        let made = Mutex<[Int: Made]>([:])
        let maker = maker
        let limits = limits
        let sleep = sleep
        let finished: Void? = await TimeLimit.run(within: limits.totalBudget, sleep: sleep) {
            for (index, file) in candidates {
                if Task.isCancelled {
                    return
                }
                guard let kind = maker.mediaKind(of: file.url) else {
                    continue
                }
                let image = await TimeLimit.run(within: limits.timeoutPerFile, sleep: sleep) {
                    await maker.thumbnail(of: file.url, maximumPixelSize: ThumbnailReference.maximumPixelSize)
                }
                guard let finished = image, let image = finished else {
                    AppLogger.clipboard.debug("No thumbnail for a copied file; it keeps its icon")
                    continue
                }
                guard Self.isValid(image) else {
                    AppLogger.clipboard.error("Skipped a file thumbnail of an unexpected size")
                    continue
                }
                made.withLock { $0[index] = Made(kind: kind, image: image) }
            }
        }
        if finished == nil {
            AppLogger.clipboard.info("Thumbnails of copied files took too long; the rest keep their icons")
        }
        return made.withLock { $0 }
    }

    /// A thumbnail is PNG data no larger than a thumbnail may be.
    static func isValid(_ image: ImageInspection.Thumbnail) -> Bool {
        let sides = 1...ThumbnailReference.maximumPixelSize
        return !image.pngData.isEmpty && sides.contains(image.pixelWidth) && sides.contains(image.pixelHeight)
    }
}
