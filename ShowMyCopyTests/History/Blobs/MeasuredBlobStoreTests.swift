import Foundation
import Synchronization
import Testing

@testable import ShowMyCopy

/// Keeps blobs in memory and counts how often they are listed, which on disk means listing the folder. Runs `hook`
/// once during the next listing, like work that writes or deletes while a count runs.
final class ListingCountingBlobStore: BlobStore {
    let inner = InMemoryBlobStore()
    private let state = Mutex((listings: 0, hook: (@Sendable () -> Void)?.none))

    var listings: Int {
        state.withLock { $0.listings }
    }

    func duringNextListing(_ hook: @escaping @Sendable () -> Void) {
        state.withLock { $0.hook = hook }
    }

    func write(_ data: Data, as id: BlobID) {
        inner.write(data, as: id)
    }

    func read(_ id: BlobID) throws(BlobStoreError) -> Data {
        try inner.read(id)
    }

    func delete(_ ids: [BlobID]) {
        inner.delete(ids)
    }

    func size(of id: BlobID) -> Int? {
        inner.size(of: id)
    }

    func totalBytes() -> Int64 {
        inner.totalBytes()
    }

    func allIDs() -> Set<BlobID> {
        let hook = state.withLock { state in
            state.listings += 1
            defer { state.hook = nil }
            return state.hook
        }
        let ids = inner.allIDs()
        hook?()
        return ids
    }
}

struct MeasuredBlobStoreTests {
    private let files = ListingCountingBlobStore()

    @Test func countsOnceThenKeepsARunningTotal() throws {
        let earlier = try files.write(Data(count: 100))
        let measured = MeasuredBlobStore(base: files)

        #expect(measured.totalBytes() == 100)
        let id = try measured.write(Data(count: 30))
        #expect(measured.totalBytes() == 130)
        try measured.delete([earlier])
        #expect(measured.totalBytes() == 30)
        try measured.delete([id, BlobID()])
        #expect(measured.totalBytes() == 0)
        #expect(files.listings == 1)
    }

    @Test func aRecountFindsWhatChangedBehindItsBack() throws {
        let measured = MeasuredBlobStore(base: files)
        _ = try measured.write(Data(count: 10))
        #expect(measured.totalBytes() == 10)
        files.write(Data(count: 5), as: BlobID())

        #expect(measured.totalBytes() == 10)
        #expect(measured.recountTotalBytes() == 15)
        #expect(measured.totalBytes() == 15)
    }

    @Test func changesMadeWhileCountingAreKept() throws {
        let kept = try files.write(Data(count: 100))
        let deleted = try files.write(Data(count: 7))
        let measured = MeasuredBlobStore(base: files)
        let added = Mutex<BlobID?>(nil)
        files.duringNextListing {
            // After the listing: the count does not see this write, nor that the other blob is gone.
            added.withLock { $0 = try? measured.write(Data(count: 20)) }
            try? measured.delete([deleted])
        }

        #expect(measured.recountTotalBytes() == 120)
        #expect(measured.totalBytes() == 120)
        #expect(files.inner.allIDs() == Set([kept] + [added.withLock { $0 }].compactMap { $0 }))
    }

    @Test func aFailedDeleteIsCountedAgain() throws {
        let failing = FailingDeleteBlobStore()
        let measured = MeasuredBlobStore(base: failing)
        let id = try measured.write(Data(count: 40))
        #expect(measured.totalBytes() == 40)
        #expect(failing.listings == 1)

        #expect(throws: BlobStoreError.deleteFailed) {
            try measured.delete([id])
        }
        #expect(measured.totalBytes() == 40)
        #expect(failing.listings == 2)
    }
}

/// Never deletes anything, like files the system will not let go of.
final class FailingDeleteBlobStore: BlobStore {
    private let inner = InMemoryBlobStore()
    private let count = Mutex(0)

    var listings: Int {
        count.withLock { $0 }
    }

    func write(_ data: Data, as id: BlobID) {
        inner.write(data, as: id)
    }

    func read(_ id: BlobID) throws(BlobStoreError) -> Data {
        try inner.read(id)
    }

    func delete(_ ids: [BlobID]) throws(BlobStoreError) {
        throw .deleteFailed
    }

    func size(of id: BlobID) -> Int? {
        inner.size(of: id)
    }

    func totalBytes() -> Int64 {
        inner.totalBytes()
    }

    func allIDs() -> Set<BlobID> {
        count.withLock { $0 += 1 }
        return inner.allIDs()
    }
}
