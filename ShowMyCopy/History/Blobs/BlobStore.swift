import Foundation
import Synchronization

/// Names one piece of data in a `BlobStore`, such as the bytes of a copied image or its thumbnail.
struct BlobID: Hashable, Sendable, CustomStringConvertible {
    let uuid: UUID

    init(uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    var description: String {
        uuid.uuidString
    }
}

/// Why a blob store call failed. The cases carry no details: the underlying errors are logged where they happen,
/// without the data or file names.
enum BlobStoreError: Error, Equatable, Sendable {
    /// The folder for the blobs could not be created or used.
    case openFailed
    case writeFailed
    /// No blob with this ID, for example because it was deleted.
    case notFound
    case readFailed
    /// Some blobs could not be deleted. The others were; the orphan sweep at the next launch tries again.
    case deleteFailed
    /// The stored blobs could not be listed.
    case listFailed
}

/// Keeps content too large for the history records, such as image bytes, outside them. The history records keep
/// only `BlobID`s, so the database stays small and an image is read only when it is shown or copied.
///
/// `Sendable` and synchronous: writing a new image happens off the main actor (see `ImageIngestor`), deleting and
/// sizing on it. Whoever removes the entry that references a blob deletes the blob; the history stores do that.
protocol BlobStore: Sendable {
    /// Stores `data` under a new ID.
    func write(_ data: Data) throws(BlobStoreError) -> BlobID

    func read(_ id: BlobID) throws(BlobStoreError) -> Data

    /// Deletes these blobs. IDs that are not stored are ignored.
    func delete(_ ids: [BlobID]) throws(BlobStoreError)

    /// The size of the blob in bytes, or nil when it is not stored.
    func size(of id: BlobID) -> Int?

    /// The total size of every stored blob in bytes.
    func totalBytes() -> Int64

    /// Every stored blob, for the sweep that deletes blobs no record references.
    func allIDs() throws(BlobStoreError) -> Set<BlobID>
}

extension BlobStore {
    /// Whether the blob is stored.
    func contains(_ id: BlobID) -> Bool {
        size(of: id) != nil
    }
}

/// Keeps blobs in memory. For tests and previews: blobs are gone when the app quits.
final class InMemoryBlobStore: BlobStore {
    private let blobs = Mutex<[BlobID: Data]>([:])

    init() {}

    func write(_ data: Data) -> BlobID {
        let id = BlobID()
        blobs.withLock { $0[id] = data }
        return id
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
