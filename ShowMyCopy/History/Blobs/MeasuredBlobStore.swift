import Foundation
import Synchronization

/// A blob store that keeps a running total of the size of its blobs, so Settings can show the size on disk without
/// listing the folder and reading the size of every file after each change.
///
/// The total is counted once from `base` when it is first asked for, and again by `recountTotalBytes()`, which the
/// Storage settings call in the background when they open; in between, every write and delete through this store
/// updates it. A delete that fails part way leaves the total unknown, so the next call counts again. Changes made
/// while a count runs are applied on top of it, so a count never loses them. Counting reads the file system: call
/// `totalBytes()` and `recountTotalBytes()` off the main actor.
final class MeasuredBlobStore: BlobStore {
    private struct State {
        /// The size of every blob, or nil while it is not known.
        var sizes: [BlobID: Int]?
        /// Writes (a size) and deletes (nil) made while a count runs, to apply on top of what it finds.
        var changedDuringCount: [BlobID: Int?]?
    }

    let base: any BlobStore
    private let state = Mutex(State())

    init(base: any BlobStore) {
        self.base = base
    }

    func write(_ data: Data, as id: BlobID) throws(BlobStoreError) {
        try base.write(data, as: id)
        note(id, size: data.count)
    }

    func read(_ id: BlobID) throws(BlobStoreError) -> Data {
        try base.read(id)
    }

    func delete(_ ids: [BlobID]) throws(BlobStoreError) {
        do {
            try base.delete(ids)
        } catch {
            // Which of them are gone is not known: count again next time.
            state.withLock { $0.sizes = nil }
            throw error
        }
        for id in ids {
            note(id, size: nil)
        }
    }

    func size(of id: BlobID) -> Int? {
        base.size(of: id)
    }

    /// The running total, counted from `base` first when it is not known.
    func totalBytes() -> Int64 {
        let known: Int64? = state.withLock { state in
            state.sizes.map { $0.values.reduce(0) { $0 + Int64($1) } }
        }
        return known ?? recountTotalBytes()
    }

    /// Counts the total again from `base`. A count already running is not repeated: its result is given instead.
    func recountTotalBytes() -> Int64 {
        let starts = state.withLock { state in
            guard state.changedDuringCount == nil else {
                return false
            }
            state.changedDuringCount = [:]
            return true
        }
        guard starts else {
            return state.withLock { state in state.sizes.map { $0.values.reduce(0) { $0 + Int64($1) } } ?? 0 }
        }
        var counted: [BlobID: Int]?
        do {
            let ids = try base.allIDs()
            counted = Dictionary(
                ids.map { ($0, base.size(of: $0) ?? 0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            // Logged by the blob store. The total stays unknown, so the next call tries again.
        }
        return state.withLock { state in
            let changed = state.changedDuringCount ?? [:]
            state.changedDuringCount = nil
            guard var sizes = counted else {
                state.sizes = nil
                return 0
            }
            for (id, size) in changed {
                sizes[id] = size
            }
            state.sizes = sizes
            return sizes.values.reduce(0) { $0 + Int64($1) }
        }
    }

    func allIDs() throws(BlobStoreError) -> Set<BlobID> {
        try base.allIDs()
    }

    private func note(_ id: BlobID, size: Int?) {
        state.withLock { state in
            if state.sizes != nil {
                state.sizes?[id] = size
            }
            if state.changedDuringCount != nil {
                state.changedDuringCount?[id] = .some(size)
            }
        }
    }
}
