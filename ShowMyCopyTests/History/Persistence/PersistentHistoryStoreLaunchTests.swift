import Foundation
import Synchronization
import Testing

@testable import ShowMyCopy

/// Counts calls and how many of them ran on the main thread, from any thread.
final class ThreadSpy: Sendable {
    private let counts = Mutex((all: 0, onMainThread: 0))

    var all: Int {
        counts.withLock { $0.all }
    }

    var onMainThread: Int {
        counts.withLock { $0.onMainThread }
    }

    func called() {
        let isMainThread = Thread.isMainThread
        counts.withLock { counts in
            counts.all += 1
            counts.onMainThread += isMainThread ? 1 : 0
        }
    }
}

/// Hashes like the app and notes the thread of every call.
struct ThreadSpyingHasher: ContentHasher {
    let spy: ThreadSpy

    func digest(of data: Data) -> ContentHash {
        spy.called()
        return SHA256ContentHasher().digest(of: data)
    }
}

/// Keeps blobs in memory and notes the thread of every call that would read the disk's metadata.
final class ThreadSpyingBlobStore: BlobStore {
    let inner: InMemoryBlobStore
    let metadata = ThreadSpy()

    init(inner: InMemoryBlobStore = InMemoryBlobStore()) {
        self.inner = inner
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
        metadata.called()
        return inner.size(of: id)
    }

    func totalBytes() -> Int64 {
        metadata.called()
        return inner.totalBytes()
    }

    func allIDs() -> Set<BlobID> {
        metadata.called()
        return inner.allIDs()
    }
}

/// Loading a long history at launch: the main actor fetches the records and builds the list; decoding, hashing and
/// reading blob metadata happen in the background.
@MainActor
struct PersistentHistoryStoreLaunchTests {
    private let disk = FakeHistoryPersistence()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func aLongHistoryIsDecodedAndCheckedOffTheMainThread() async throws {
        let saved = InMemoryBlobStore()
        let earlier = disk.makeStore(retention: RetentionPolicy(entryLimit: 1000), now: start, blobs: saved)
        for index in 0..<999 {
            earlier.record(text: "entry \(index)", sourceApp: nil, at: start + Double(index))
        }
        let image = try ContentFixtures.storedImage(in: saved)
        earlier.record(.image(image), sourceApp: nil, at: start + 1000)
        let orphan = try saved.write(Data("left by a crash".utf8))
        let blobs = ThreadSpyingBlobStore(inner: saved)
        let hashes = ThreadSpy()

        let store = await PersistentHistoryStore.load(
            persistence: disk, sealer: FakeSecretSealer(), savesPasswords: true,
            retention: RetentionPolicy(entryLimit: 1000),
            hasher: ThreadSpyingHasher(spy: hashes), now: { [start] in start + 2000 }, openError: nil, blobs: blobs,
            leftovers: nil)

        #expect(store.entries.count == 1000)
        #expect(store.entries.first?.content == .image(image))
        #expect(hashes.all >= 1000)
        #expect(hashes.onMainThread == 0)
        #expect(blobs.metadata.all > 0)
        #expect(blobs.metadata.onMainThread == 0)
        // The sweep still found the blob no record uses.
        #expect(!blobs.inner.allIDs().contains(orphan))
        #expect(blobs.inner.allIDs() == Set(image.blobIDs))
    }

    @Test func loadingInTheBackgroundFindsWhatLoadingAtOnceFinds() async throws {
        let earlier = disk.makeStore(now: start)
        earlier.record(text: "plain", sourceApp: nil, at: start)
        earlier.record(text: "expired", sourceApp: nil, at: start + 1, concealed: true, expiresAt: start + 2)
        earlier.record(text: "hunter2", sourceApp: nil, at: start + 3, concealed: true, expiresAt: start + 600)

        let loaded = await PersistentHistoryStore.load(
            persistence: disk, sealer: FakeSecretSealer(), savesPasswords: true, retention: .default,
            now: { [start] in start + 10 }, openError: nil, blobs: nil, leftovers: nil)

        #expect(loaded.entries.map(\.text) == ["hunter2", "plain"])
        #expect(disk.records.count == 2)
        #expect(loaded.storageError == nil)
    }

    @Test func aHistoryThatCannotBeReadStartsEmptyAndLeavesTheDiskAlone() async {
        disk.makeStore(now: start).record(text: "saved", sourceApp: nil, at: start)
        disk.failing = [.loadAll]

        let store = await PersistentHistoryStore.load(
            persistence: disk, sealer: FakeSecretSealer(), savesPasswords: true, retention: .default,
            now: { [start] in start + 1 }, openError: nil, blobs: nil, leftovers: nil)

        #expect(store.entries.isEmpty)
        #expect(store.storageError == .loadFailed)
        #expect(disk.records.count == 1)
    }
}
