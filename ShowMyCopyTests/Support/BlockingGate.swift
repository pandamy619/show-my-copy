import Dispatch
import Foundation
import Synchronization

/// Stops synchronous background work at one point until the test lets it go on, so a test can change the history
/// while the work is in flight. The work's thread waits on a semaphore; the test waits for it to arrive without
/// blocking the main actor and without real time passing.
final class BlockingGate: Sendable {
    private let arrived = DispatchSemaphore(value: 0)
    private let opened = DispatchSemaphore(value: 0)
    private let isArmed = Mutex(false)

    /// The next work that passes the gate stops there.
    func arm() {
        isArmed.withLock { $0 = true }
    }

    /// Called by fakes on the work's thread: stops there when the gate is armed, once.
    func pass() {
        let stops = isArmed.withLock { armed in
            defer { armed = false }
            return armed
        }
        guard stops else {
            return
        }
        arrived.signal()
        opened.wait()
    }

    /// Waits until the work stopped at the gate.
    func waitUntilReached() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { [arrived] in
                arrived.wait()
                continuation.resume()
            }
        }
    }

    /// Lets the work go on.
    func open() {
        opened.signal()
    }
}

/// A blob store in memory whose `write` stops at `gate` after writing, so the blob exists before the work that
/// wrote it hands it on.
final class GatedBlobStore: BlobStore {
    let gate = BlockingGate()
    private let base = InMemoryBlobStore()
    private let writes = Mutex(0)
    private let stopsAfterWrite = Mutex<Int?>(nil)

    /// The `count`-th write from now stops at the gate after writing.
    func stop(afterWrites count: Int) {
        stopsAfterWrite.withLock { $0 = count }
        writes.withLock { $0 = 0 }
        gate.arm()
    }

    func write(_ data: Data, as id: BlobID) throws(BlobStoreError) {
        try base.write(data, as: id)
        let count = writes.withLock { count in
            count += 1
            return count
        }
        if stopsAfterWrite.withLock({ $0 == count }) {
            gate.pass()
        }
    }

    func read(_ id: BlobID) throws(BlobStoreError) -> Data { try base.read(id) }
    func delete(_ ids: [BlobID]) { base.delete(ids) }
    func size(of id: BlobID) -> Int? { base.size(of: id) }
    func totalBytes() -> Int64 { base.totalBytes() }
    func allIDs() -> Set<BlobID> { base.allIDs() }
}

/// SHA-256 that stops at `gate` before hashing when the gate is armed: the first thing `ImageIngestor` does.
struct GatedHasher: ContentHasher {
    let gate: BlockingGate

    func digest(of data: Data) -> ContentHash {
        gate.pass()
        return SHA256ContentHasher().digest(of: data)
    }
}
