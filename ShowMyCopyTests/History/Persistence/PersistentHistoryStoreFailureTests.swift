import Foundation
import Testing

@testable import ShowMyCopy

/// What is left on disk when writes fail part way, and what the write after a failure may touch.
@MainActor
struct PersistentHistoryStoreFailureTests {
    private let disk = FakeHistoryPersistence()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeStore(now: Date? = nil, blobs: (any BlobStore)? = nil) -> PersistentHistoryStore {
        disk.makeStore(now: now ?? start, blobs: blobs)
    }

    private func savedTexts() -> Set<String> {
        disk.savedTexts()
    }

    /// An image record on disk that a store without a blob store leaves unloaded.
    private func saveImageRecord() throws -> UUID {
        let blobs = InMemoryBlobStore()
        let image = try ContentFixtures.storedImage(in: blobs)
        return makeStore(blobs: blobs).record(.image(image), sourceApp: nil, at: start - 10)
    }

    // MARK: - One transaction

    @Test func theWriteAfterAFailedOneIsASingleChange() {
        let store = makeStore()
        store.record(text: "a", sourceApp: nil, at: start)
        disk.failing = [.apply]
        store.record(text: "b", sourceApp: nil, at: start + 1)
        disk.failing = []
        disk.resetCalls()

        store.record(text: "c", sourceApp: nil, at: start + 2)
        #expect(disk.calls == [.apply])
        #expect(disk.changes.first?.deletesAll == false)
        #expect(savedTexts() == ["a", "b", "c"])
    }

    @Test(arguments: 1...3)
    func whicheverOperationFailsTheSavedEntriesStayOnDisk(failingOperation: Int) {
        let store = makeStore()
        store.record(text: "a", sourceApp: nil, at: start)
        store.record(text: "b", sourceApp: nil, at: start + 1)
        disk.failingCalls = [disk.nextCall]
        store.record(text: "c", sourceApp: nil, at: start + 2)

        // Disk still full: the n-th operation of the catch-up fails, whatever it is.
        disk.failingCalls = [disk.nextCall + failingOperation - 1]
        for index in 0..<3 {
            store.record(text: "more \(index)", sourceApp: nil, at: start + 3 + Double(index))
            #expect(savedTexts().isSuperset(of: ["a", "b"]))
        }
        store.record(text: "last", sourceApp: nil, at: start + 10)
        #expect(savedTexts() == ["a", "b", "c", "more 0", "more 1", "more 2", "last"])
        #expect(store.storageError == nil)
    }

    @Test func theWriteAfterAFailedOneWritesOnlyWhatIsNotSavedYet() throws {
        let store = makeStore()
        let saved = store.record(text: "a", sourceApp: nil, at: start)
        disk.failing = [.apply]
        let failed = store.record(text: "b", sourceApp: nil, at: start + 1)
        disk.failing = []
        disk.resetCalls()

        let next = store.record(text: "c", sourceApp: nil, at: start + 2)
        let change = try #require(disk.changes.first)
        #expect(Set(change.saved.map(\.id)) == [failed, next])
        #expect(!change.deleted.contains(saved))
    }

    @Test func anEntryRemovedWhileWritesFailIsDeletedFromDisk() {
        let store = makeStore()
        let removed = store.record(text: "a", sourceApp: nil, at: start)
        store.record(text: "b", sourceApp: nil, at: start + 1)
        disk.failing = [.apply]
        store.remove(id: removed)
        disk.failing = []

        store.record(text: "c", sourceApp: nil, at: start + 2)
        #expect(savedTexts() == ["b", "c"])
        #expect(disk.record(removed) == nil)
    }

    @Test func aDeleteThatFailedAtLaunchIsMadeGoodByTheNextChange() {
        let first = makeStore()
        first.record(text: "plain", sourceApp: nil, at: start)
        let expired = first.record(
            text: "hunter2", sourceApp: nil, at: start + 1, concealed: true, expiresAt: start + 60)
        disk.failing = [.apply]

        let store = makeStore(now: start + 120)
        #expect(store.entries.map(\.text) == ["plain"])
        #expect(store.storageError == .saveFailed)
        disk.failing = []

        store.record(text: "next", sourceApp: nil, at: start + 121)
        #expect(disk.record(expired) == nil)
        #expect(savedTexts() == ["plain", "next"])
    }

    // MARK: - Records this session does not own

    @Test func theWriteAfterAFailedOneKeepsImagesNotLoadedWithoutABlobStore() throws {
        let imageID = try saveImageRecord()
        let store = makeStore()
        #expect(store.entries.isEmpty)
        disk.failing = [.apply]
        store.record(text: "a", sourceApp: nil, at: start)
        disk.failing = []

        store.record(text: "b", sourceApp: nil, at: start + 1)
        #expect(disk.record(imageID) != nil)
        #expect(savedTexts() == ["a", "b"])
    }

    @Test func writesAfterAFailedLoadNeverTouchTheSavedHistory() throws {
        let first = makeStore()
        let older = [
            first.record(text: "a", sourceApp: nil, at: start),
            first.record(text: "b", sourceApp: nil, at: start + 1),
        ]
        disk.failing = [.loadAll]
        let store = makeStore(now: start + 2)
        disk.failing = [.apply]
        let removed = store.record(text: "c", sourceApp: nil, at: start + 2)
        disk.failing = []
        disk.resetCalls()

        store.record(text: "d", sourceApp: nil, at: start + 3)
        store.remove(id: removed)
        #expect(savedTexts() == ["a", "b", "d"])
        #expect(store.storageError == .loadFailed)
        for change in disk.changes {
            #expect(!change.deletesAll)
            #expect(Set(change.deleted).isDisjoint(with: older))
        }
    }

    // MARK: - Clear History

    @Test func aFailedClearIsDoneWithTheNextChange() throws {
        let unloaded = try saveImageRecord()
        let store = makeStore()
        store.record(text: "a", sourceApp: nil, at: start)
        disk.failing = [.apply]
        store.clear()
        disk.failing = []

        store.record(text: "b", sourceApp: nil, at: start + 1)
        #expect(savedTexts() == ["b"])
        #expect(disk.record(unloaded) == nil)
        #expect(store.storageError == nil)
    }

    @Test func aClearThatFailsAgainIsTriedAgainWithTheNextChange() {
        let store = makeStore()
        store.record(text: "a", sourceApp: nil, at: start)
        disk.failing = [.apply]
        store.clear()
        store.record(text: "b", sourceApp: nil, at: start + 1)
        disk.failing = []

        store.record(text: "c", sourceApp: nil, at: start + 2)
        #expect(savedTexts() == ["b", "c"])
    }
}
