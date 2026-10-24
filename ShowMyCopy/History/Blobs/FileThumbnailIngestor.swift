import Foundation
import Synchronization
import os

/// Gives copied photo and video files their thumbnails, while the app can still read them.
///
/// After a relaunch the sandbox no longer lets the app read a copied file, so its thumbnail is made right when it is
/// copied and kept in the blob store, like an image's thumbnail. Only the thumbnail is kept, never the file's data.
/// The work is bounded: only the first `Limits.maximumFiles` files of a copy are looked at (those without a
/// thumbnail), each gets at most `Limits.timeoutPerFile`, and all of them together `Limits.totalBudget`. A file that
/// is not a photo or video, cannot be read, is not on this Mac or takes too long keeps its icon. Runs off the main
/// actor.
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

    let blobs: any BlobStore
    let maker: any FileThumbnailMaking
    let limits: Limits
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        blobs: any BlobStore,
        maker: any FileThumbnailMaking,
        limits: Limits = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.blobs = blobs
        self.maker = maker
        self.limits = limits
        self.sleep = sleep
    }

    /// `files` in the same order, each with the thumbnail made now or none: thumbnails for the photos and videos
    /// among the first `limits.maximumFiles` that have none yet. A thumbnail a file already had is not returned, so
    /// handing the result on or discarding it never touches it. The new thumbnails are written to the blob store;
    /// whoever does not hand them to a history store calls `discard`.
    @concurrent
    func ingest(_ files: [FileReference]) async -> [FileReference] {
        let made = await makeThumbnails(for: files)
        var result = files.map { $0.withThumbnail(nil) }
        for (index, thumbnail) in made.sorted(by: { $0.key < $1.key }) {
            let id: BlobID
            do {
                id = try blobs.write(thumbnail.image.pngData)
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

    /// Deletes the thumbnails `ingest` wrote for files that are not recorded after all.
    func discard(_ files: [FileReference]) {
        let ids = files.compactMap(\.thumbnail?.blobID)
        guard !ids.isEmpty else {
            return
        }
        do {
            try blobs.delete(ids)
        } catch {
            AppLogger.history.error("Could not delete thumbnails that are not used; they go at the next launch")
        }
    }

    private struct Made: Sendable {
        let kind: FileThumbnail.Kind
        let image: ImageInspection.Thumbnail
    }

    /// The thumbnails made in time, by the file's position. One file at a time, so a copy of many videos does not
    /// start many QuickLook requests at once.
    private func makeThumbnails(for files: [FileReference]) async -> [Int: Made] {
        // Only file URLs: QuickLook is never asked for anything that could be fetched over the network.
        let candidates = files.prefix(max(limits.maximumFiles, 0)).enumerated().filter {
            $0.element.url.isFileURL && $0.element.thumbnail == nil
        }
        guard !candidates.isEmpty else {
            return [:]
        }
        let made = Mutex<[Int: Made]>([:])
        let maker = maker
        let limits = limits
        let sleep = sleep
        let finished: Void? = await Self.run(within: limits.totalBudget, sleep: sleep) {
            for (index, file) in candidates {
                if Task.isCancelled {
                    return
                }
                guard let kind = maker.mediaKind(of: file.url) else {
                    continue
                }
                let image = await Self.run(within: limits.timeoutPerFile, sleep: sleep) {
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

    private enum Outcome<Value: Sendable>: Sendable {
        case finished(Value)
        case timedOut
    }

    /// Runs `work` until it finishes or `timeout` passes, whichever is first, and cancels the other. Nil when the
    /// time ran out or the calling task was cancelled. `work` must stop soon after it is cancelled.
    static func run<Value: Sendable>(
        within timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        _ work: @escaping @Sendable () async -> Value
    ) async -> Value? {
        await withTaskGroup(of: Outcome<Value>.self) { group in
            group.addTask {
                .finished(await work())
            }
            group.addTask {
                do {
                    try await sleep(timeout)
                } catch {
                    // Cancelled: the work finished first, or the caller was cancelled.
                }
                return .timedOut
            }
            let first = await group.next()
            group.cancelAll()
            guard case .finished(let value) = first else {
                return nil
            }
            return value
        }
    }
}
