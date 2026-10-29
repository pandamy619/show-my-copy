import Foundation

/// Measures how many bytes a saved history takes on disk (`PersistentHistoryStore.storedBytes(recountingBlobs:)`).
/// It reads the file system, so it runs off the main actor.
enum SavedHistorySize {
    /// The store's files, `leftovers` and the saved images together, or nil when nothing is saved in files. Saved
    /// images come from the blob store's running total, or are counted again with `recountingBlobs`.
    @concurrent
    static func measure(
        _ persistence: any HistoryPersistence,
        _ leftovers: (any HistoryLeftovers)?,
        _ blobs: (any BlobStore)?,
        recountingBlobs: Bool
    ) async -> Int64? {
        let stores = [persistence.storedBytes(), leftovers?.totalBytes()].compactMap { $0 }
        guard !stores.isEmpty else {
            return nil
        }
        let blobBytes = recountingBlobs ? blobs?.recountTotalBytes() : blobs?.totalBytes()
        return stores.reduce(0, +) + (blobBytes ?? 0)
    }
}
