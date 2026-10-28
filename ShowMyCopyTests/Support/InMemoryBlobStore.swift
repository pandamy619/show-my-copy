import Foundation
import Synchronization

@testable import ShowMyCopy

/// Keeps blobs in memory, as a stand-in for `FileBlobStore`.
final class InMemoryBlobStore: BlobStore {
    private let blobs = Mutex<[BlobID: Data]>([:])

    init() {}

    func write(_ data: Data, as id: BlobID) {
        blobs.withLock { $0[id] = data }
    }

    func read(_ id: BlobID) throws(BlobStoreError) -> Data {
        guard let data = blobs.withLock({ $0[id] }) else {
            throw .notFound
        }
        return data
    }

    func delete(_ ids: [BlobID]) {
        blobs.withLock { blobs in
            for id in ids {
                blobs[id] = nil
            }
        }
    }

    func size(of id: BlobID) -> Int? {
        blobs.withLock { $0[id]?.count }
    }

    func totalBytes() -> Int64 {
        blobs.withLock { $0.values.reduce(0) { $0 + Int64($1.count) } }
    }

    func allIDs() -> Set<BlobID> {
        blobs.withLock { Set($0.keys) }
    }
}
