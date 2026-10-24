import Foundation

/// Thumbnails for the image rows of the history window.
///
/// A row asks for its thumbnail when it appears, so only the rows on screen are read. The thumbnail blob is read
/// and decoded off the main actor, and the result is kept in a small cache bounded by count and decoded bytes, so
/// scrolling back shows it at once. Two rows asking for the same thumbnail share one load. A thumbnail that could not
/// be loaded is remembered for a while, so a broken blob is not read again on every scroll.
@MainActor
final class ThumbnailProvider {
    struct Limits: Equatable, Sendable {
        /// How many decoded thumbnails are kept.
        let count: Int
        /// How many bytes of decoded pixels are kept. A 256 × 256 thumbnail takes 256 KB. The app runs all day in
        /// the background, so this stays small; reading a thumbnail again is quick.
        let bytes: Int
        /// How many failed thumbnails are remembered.
        let failures: Int

        static let standard = Limits(count: 100, bytes: 16 * 1024 * 1024, failures: 500)
    }

    private let blobs: (any BlobStore)?
    private let decoder: (any PreviewImageDecoding)?
    private var cache: BoundedCache<BlobID, any PreviewImage>
    private var failures: BoundedCache<BlobID, Bool>
    private var loads: [BlobID: Task<(any PreviewImage)?, Never>] = [:]

    /// How many thumbnails were read from the blob store. Tests read it to check that the cache is used.
    private(set) var loadCount = 0

    init(blobs: (any BlobStore)?, decoder: (any PreviewImageDecoding)?, limits: Limits = .standard) {
        self.blobs = blobs
        self.decoder = decoder
        cache = BoundedCache(countLimit: limits.count, costLimit: limits.bytes)
        failures = BoundedCache(countLimit: limits.failures, costLimit: 0)
    }

    /// What a row can show right away: the cached thumbnail, `failed` when there is none to load, or `loading`.
    func state(for image: ImageReference) -> PreviewLoadState<any PreviewImage> {
        guard let id = image.thumbnail?.blobID, blobs != nil, decoder != nil else {
            return .failed
        }
        if let cached = cache.value(for: id) {
            return .loaded(cached)
        }
        return failures.contains(id) ? .failed : .loading
    }

    /// Loads the thumbnail of `image`, or gives the cached one. Nil when the image has no thumbnail or it could not
    /// be read or decoded. Cancelling the caller (a row that scrolled away) does not cancel the shared load: its
    /// result is still cached for the next time the row appears.
    func thumbnail(for image: ImageReference) async -> (any PreviewImage)? {
        guard let id = image.thumbnail?.blobID, let blobs, let decoder else {
            return nil
        }
        if let cached = cache.value(for: id) {
            return cached
        }
        if failures.contains(id) {
            return nil
        }
        if let running = loads[id] {
            return await running.value
        }
        loadCount += 1
        let task = Task { @MainActor [weak self] () -> (any PreviewImage)? in
            let loaded = await PreviewImageLoader.load(
                id, from: blobs, decoder: decoder, maximumPixelSize: ThumbnailReference.maximumPixelSize)
            self?.finish(id, with: loaded)
            return loaded
        }
        loads[id] = task
        return await task.value
    }

    private func finish(_ id: BlobID, with image: (any PreviewImage)?) {
        loads[id] = nil
        if let image {
            cache.insert(image, for: id, cost: image.decodedByteCount)
        } else {
            failures.insert(true, for: id)
        }
    }
}
