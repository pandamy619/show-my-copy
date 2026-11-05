import Foundation
import Testing

@testable import ShowMyCopy

/// A saved history that holds the same content in several records, as two app processes writing one store leave it,
/// is loaded with each content once, and the extra records go in one transaction.
@MainActor
struct PersistentHistoryStoreDuplicateTests {
    private let disk = FakeHistoryPersistence()
    private let blobs = InMemoryBlobStore()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let coder = StoredEntryCoder(sealer: FakeSecretSealer(), hasher: SHA256ContentHasher())

    private func save(_ entries: [ClipboardEntry]) throws {
        try disk.insert(entries.compactMap { try coder.record(for: $0) })
        disk.resetCalls()
    }

    private func text(_ text: String, at offset: TimeInterval, pinned: Bool = false) -> ClipboardEntry {
        let content = ClipboardContent.text(text)
        return ClipboardEntry(
            content: content, contentHash: SHA256ContentHasher().hash(content), date: start + offset,
            sourceApp: nil, isPinned: pinned)
    }

    private func load() -> PersistentHistoryStore {
        disk.makeStore(now: start + 100, blobs: blobs)
    }

    @Test func theNewestOfEqualEntriesIsKeptAndTheOthersAreDeletedInOneTransaction() throws {
        let older = text("alpha", at: 1)
        let newer = text("alpha", at: 3)
        let other = text("beta", at: 2)
        try save([older, newer, other])

        let store = load()
        #expect(store.entries.map(\.id) == [newer.id, other.id])
        #expect(Set(disk.records.keys) == [newer.id, other.id])
        #expect(disk.changes == [StoredChange(deleted: [older.id])])
        #expect(store.storageError == nil)

        #expect(load().entries.map(\.id) == [newer.id, other.id])
    }

    @Test func aPinnedCopyIsKeptOverANewerOne() throws {
        let pinned = text("alpha", at: 1, pinned: true)
        let newer = text("alpha", at: 3)
        try save([pinned, newer])

        let store = load()
        #expect(store.entries.map(\.id) == [pinned.id])
        #expect(store.entries.first?.isPinned == true)
        #expect(Set(disk.records.keys) == [pinned.id])
    }

    @Test func aConcealedCopyIsKeptOverANewerPlainOne() throws {
        let content = ClipboardContent.text("hunter2")
        let hash = SHA256ContentHasher().hash(content)
        let concealed = ClipboardEntry(
            content: content, contentHash: hash, date: start + 1, sourceApp: nil, isConcealed: true,
            expiresAt: start + 600)
        let plain = ClipboardEntry(content: content, contentHash: hash, date: start + 3, sourceApp: nil)
        try save([concealed, plain])

        let store = load()
        #expect(store.entries.map(\.id) == [concealed.id])
        #expect(Set(disk.records.keys) == [concealed.id])
    }

    @Test func theImageDataOfADeletedCopyGoesWithIt() throws {
        func image(_ blob: BlobID, at offset: TimeInterval) -> ClipboardEntry {
            let content = ClipboardContent.image(
                ImageReference(
                    blobID: blob, typeIdentifier: "public.png", pixelWidth: 2, pixelHeight: 2, byteSize: 2,
                    contentHash: ContentHash(bytes: Array(repeating: 7, count: 32)), thumbnail: nil))
            return ClipboardEntry(
                content: content, contentHash: SHA256ContentHasher().hash(content), date: start + offset,
                sourceApp: nil)
        }
        let olderBlob = BlobID(uuid: UUID())
        let newerBlob = BlobID(uuid: UUID())
        blobs.write(Data([0x89, 0x50]), as: olderBlob)
        blobs.write(Data([0x89, 0x50]), as: newerBlob)
        let older = image(olderBlob, at: 1)
        let newer = image(newerBlob, at: 2)
        try save([older, newer])

        let store = load()
        #expect(store.entries.map(\.id) == [newer.id])
        #expect(Set(disk.records.keys) == [newer.id])
        #expect(blobs.allIDs() == [newerBlob])
    }

    /// The copies go with the next write when deleting them fails, like other records loading found unwanted.
    @Test func copiesThatCouldNotBeDeletedGoWithTheNextWrite() throws {
        let older = text("alpha", at: 1)
        let newer = text("alpha", at: 3)
        try save([older, newer])
        disk.failingCalls = [disk.nextCall + 1]

        let store = load()
        #expect(store.entries.map(\.id) == [newer.id])
        #expect(disk.records.count == 2)
        #expect(store.storageError == .saveFailed)

        store.record(text: "beta", sourceApp: nil, at: start + 200)
        #expect(Set(disk.records.keys) == Set(store.entries.map(\.id)))
    }

    /// Nothing is deleted after the saved history could not be read: what it holds is not known.
    @Test func nothingIsDeletedAfterAFailedLoad() throws {
        try save([text("alpha", at: 1), text("alpha", at: 3)])
        disk.failing = [.loadAll]

        let store = load()
        #expect(store.entries.isEmpty)
        #expect(disk.records.count == 2)
        #expect(!disk.calls.contains(.apply))
    }
}
