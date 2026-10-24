import Foundation
import Synchronization

/// The blob store the history stores share with the work that fills in recorded copies in the background (image
/// data, thumbnails), with a registry of the blobs that work holds.
///
/// Background work writes its blobs only through a `BlobReservation`, and it reserves each ID before the blob exists.
/// Until the work releases them, held blobs are left alone by everything that deletes blobs: removing an entry, the
/// limits, Clear History and the sweep of blobs no saved record uses, which does not even see them (`allIDs()`).
/// A deletion asked for meanwhile is put off. When the work is done it hands its result to the history and releases
/// the reservation, which gives back the blobs it wrote and those whose deletion was put off; the work's owner
/// deletes the ones no entry uses. So a result that arrives for an entry that is gone leaves nothing behind, and
/// a blob is never deleted under work that is about to hand it on.
final class InFlightBlobStore: BlobStore {
    private struct Registry {
        /// How many reservations hold each blob.
        var holds: [BlobID: Int] = [:]
        /// Held blobs someone asked to delete.
        var putOff: Set<BlobID> = []
        /// Bytes of reserved blobs not written yet.
        var unwritten: [BlobID: Data] = [:]
    }

    let base: any BlobStore
    private let registry = Mutex(Registry())

    init(base: any BlobStore) {
        self.base = base
    }

    /// Starts a reservation for one piece of background work.
    func reservation() -> BlobReservation {
        BlobReservation(store: self)
    }

    func write(_ data: Data, as id: BlobID) throws(BlobStoreError) {
        try base.write(data, as: id)
    }

    /// The blob, or the bytes a reservation keeps for it while it is not written yet.
    func read(_ id: BlobID) throws(BlobStoreError) -> Data {
        if let data = registry.withLock({ $0.unwritten[id] }) {
            return data
        }
        return try base.read(id)
    }

    /// Deletes the blobs no work holds. The deletion of held blobs is put off until their work releases them.
    func delete(_ ids: [BlobID]) throws(BlobStoreError) {
        let free = registry.withLock { registry in
            ids.filter { id in
                guard registry.holds[id] != nil else {
                    return true
                }
                registry.putOff.insert(id)
                return false
            }
        }
        guard !free.isEmpty else {
            return
        }
        try base.delete(free)
    }

    func size(of id: BlobID) -> Int? {
        base.size(of: id)
    }

    func totalBytes() -> Int64 {
        base.totalBytes()
    }

    func recountTotalBytes() -> Int64 {
        base.recountTotalBytes()
    }

    /// The stored blobs that no work holds: those a sweep may judge.
    func allIDs() throws(BlobStoreError) -> Set<BlobID> {
        let stored = try base.allIDs()
        return registry.withLock { registry in
            stored.filter { registry.holds[$0] == nil }
        }
    }

    fileprivate func hold(_ ids: [BlobID]) {
        registry.withLock { registry in
            for id in ids {
                registry.holds[id, default: 0] += 1
            }
        }
    }

    fileprivate func keepUnwritten(_ data: Data, for id: BlobID) {
        registry.withLock { $0.unwritten[id] = data }
    }

    /// Ends one hold of each of `ids`. Returns those no longer held whose deletion was put off.
    fileprivate func release(_ ids: [BlobID]) -> [BlobID] {
        registry.withLock { registry in
            var putOff: [BlobID] = []
            for id in ids {
                guard let count = registry.holds[id] else {
                    continue
                }
                guard count <= 1 else {
                    registry.holds[id] = count - 1
                    continue
                }
                registry.holds[id] = nil
                registry.unwritten[id] = nil
                if registry.putOff.remove(id) != nil {
                    putOff.append(id)
                }
            }
            return putOff
        }
    }
}

/// The blobs one piece of background work writes or holds, until it releases them.
final class BlobReservation: Sendable {
    private struct State {
        /// IDs reserved for blobs this work writes.
        var reserved: [BlobID] = []
        /// Blobs that existed before and that this work may hand on, such as the image a copy repeats.
        var held: [BlobID] = []
        var isReleased = false
    }

    private let store: InFlightBlobStore
    private let state = Mutex(State())

    fileprivate init(store: InFlightBlobStore) {
        self.store = store
    }

    /// A new ID, held from now on, for a blob this work will write.
    func newID() -> BlobID {
        let id = BlobID()
        store.hold([id])
        state.withLock { $0.reserved.append(id) }
        return id
    }

    /// Writes `data` as a new blob, held until the reservation is released.
    func write(_ data: Data) throws(BlobStoreError) -> BlobID {
        let id = newID()
        try store.base.write(data, as: id)
        return id
    }

    /// Writes `data` under an ID from `newID()`.
    func write(_ data: Data, as id: BlobID) throws(BlobStoreError) {
        try store.base.write(data, as: id)
    }

    /// Holds blobs that exist already and that this work may hand to an entry.
    func hold(_ ids: [BlobID]) {
        store.hold(ids)
        state.withLock { $0.held += ids }
    }

    /// Keeps the bytes of a blob this work has not written yet, so `read` gives them meanwhile: an image can be
    /// copied back or previewed before its data is saved. Dropped when the reservation is released.
    func keepUnwritten(_ data: Data, for id: BlobID) {
        store.keepUnwritten(data, for: id)
    }

    /// Ends the hold. Returns the blobs this work wrote or reserved, and the held blobs whose deletion was put
    /// off and that no other work holds: whoever owns the work deletes those no entry uses.
    func release() -> [BlobID] {
        let released = state.withLock { state -> State? in
            guard !state.isReleased else {
                return nil
            }
            state.isReleased = true
            return state
        }
        guard let released else {
            return []
        }
        let putOff = store.release(released.reserved + released.held)
        let reserved = Set(released.reserved)
        return released.reserved + putOff.filter { !reserved.contains($0) }
    }
}
