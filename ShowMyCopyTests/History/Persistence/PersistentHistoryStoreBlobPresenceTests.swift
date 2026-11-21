import Foundation
import Testing

@testable import ShowMyCopy

/// A blob store that cannot tell whether some blobs are there, as the file store cannot when a file's metadata
/// will not read: an uncertain state, which must never cost the entry its record.
final class UncertainBlobStore: BlobStore {
    let inner: InMemoryBlobStore
    let uncertain: Set<BlobID>

    init(inner: InMemoryBlobStore, uncertain: Set<BlobID>) {
        self.inner = inner
        self.uncertain = uncertain
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
        uncertain.contains(id) ? nil : inner.size(of: id)
    }

    func presence(of id: BlobID) -> BlobPresence {
        uncertain.contains(id) ? .unknown : inner.presence(of: id)
    }

    func totalBytes() -> Int64 {
        inner.totalBytes()
    }

    func allIDs() -> Set<BlobID> {
        inner.allIDs()
    }
}

@MainActor
struct PersistentHistoryStoreBlobPresenceTests {
    private let disk = FakeHistoryPersistence()
    private let blobs = InMemoryBlobStore()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func anImageWhoseBlobCannotBeLookedAtIsLeftOnDiskWithItsBlob() throws {
        let first = disk.makeStore(now: start, blobs: blobs)
        let image = try ContentFixtures.storedImage(in: blobs)
        let id = first.record(.image(image), sourceApp: nil, at: start)
        first.record(text: "plain", sourceApp: nil, at: start + 1)
        let record = try #require(disk.record(id))
        let uncertain = UncertainBlobStore(inner: blobs, uncertain: Set(image.blobIDs.prefix(1)))

        let store = disk.makeStore(now: start + 2, blobs: uncertain)

        #expect(store.entries.map(\.text) == ["plain"])
        #expect(disk.record(id) == record)
        #expect(blobs.allIDs() == Set(image.blobIDs))
        // A launch that can look at the blob loads the image again.
        #expect(disk.makeStore(now: start + 3, blobs: blobs).entries.contains { $0.id == id })
    }

    @Test func anImageWhoseBlobIsGoneIsStillDeleted() throws {
        let first = disk.makeStore(now: start, blobs: blobs)
        let image = try ContentFixtures.storedImage(in: blobs)
        let id = first.record(.image(image), sourceApp: nil, at: start)
        blobs.delete([image.blobIDs[0]])

        let store = disk.makeStore(now: start + 1, blobs: UncertainBlobStore(inner: blobs, uncertain: []))

        #expect(store.entries.isEmpty)
        #expect(disk.record(id) == nil)
    }

    @Test func presenceOfAStoreWhoseLookUpsCannotFailFollowsItsSize() {
        let id = BlobID()
        #expect(blobs.presence(of: id) == .missing)
        #expect(!blobs.contains(id))
        blobs.write(Data([1]), as: id)
        #expect(blobs.presence(of: id) == .present)
        #expect(blobs.contains(id))
        #expect(!UncertainBlobStore(inner: blobs, uncertain: [id]).contains(id))
    }
}
