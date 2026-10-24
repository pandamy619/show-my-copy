import Foundation
import Testing

@testable import ShowMyCopy

/// An image is recorded before its data is saved and completed afterwards (`completeImage`). Both history stores
/// must do that alike, so every test runs against each.
@MainActor
struct HistoryStoreImageCompletionTests {
    enum Store: CaseIterable, Sendable {
        case inMemory
        case persistent
    }

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let blobs = InMemoryBlobStore()
    private let disk = FakeHistoryPersistence()
    private let safari = SourceApp(bundleIdentifier: "com.apple.Safari", name: "Safari")

    private func makeStore(_ store: Store) -> any HistoryStore {
        switch store {
        case .inMemory:
            InMemoryHistoryStore(blobs: blobs)
        case .persistent:
            PersistentHistoryStore.loadedNow(
                persistence: disk, sealer: nil, savesPasswords: false, now: start, blobs: blobs)
        }
    }

    private func unsaved(byteSize: Int = 6) -> ImageReference {
        .unsaved(blobID: BlobID(), typeIdentifier: "public.png", byteSize: byteSize)
    }

    private func saved(_ byte: UInt8 = 7, as unsaved: ImageReference? = nil) throws -> ImageReference {
        let image = try ContentFixtures.storedImage(in: blobs, bytes: Data(repeating: byte, count: 6))
        guard let unsaved else {
            return image
        }
        // Saved under the ID the unsaved image reserved, as `ImageIngestor` does.
        blobs.write(try blobs.read(image.blobID), as: unsaved.blobID)
        blobs.delete([image.blobID])
        return ImageReference(
            blobID: unsaved.blobID, typeIdentifier: image.typeIdentifier, pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight, byteSize: image.byteSize, contentHash: image.contentHash,
            thumbnail: image.thumbnail)
    }

    @Test func unsavedImageMatchesNoOtherImage() {
        let first = unsaved()
        let second = unsaved()
        #expect(!first.isSaved)
        #expect(first.contentHash != second.contentHash)
        #expect(first.thumbnail == nil)
        #expect(first.blobIDs == [first.blobID])
        #expect(ImageReference.unsaved(blobID: first.blobID, typeIdentifier: "public.png", byteSize: 6) == first)
    }

    @Test(arguments: Store.allCases)
    func completedImageKeepsItsPlaceDateSourceAndCurrentState(store kind: Store) throws {
        let store = makeStore(kind)
        let pending = unsaved()
        let id = store.record(.image(pending), sourceApp: safari, at: start)
        store.record(text: "newer", sourceApp: nil, at: start + 1)
        store.record(.image(pending), sourceApp: safari, at: start + 2)
        #expect(store.entries.first?.id == id)
        #expect(store.entries.first?.previewText == "PNG")

        let image = try saved(as: pending)
        store.completeImage(pending, with: image, keepsEarlierCopy: false)

        let entry = try #require(store.entries.first)
        #expect(entry.id == id)
        #expect(entry.content == .image(image))
        #expect(entry.contentHash == SHA256ContentHasher().hash(.image(image)))
        #expect(entry.date == start + 2)
        #expect(entry.sourceApp == safari)
        #expect(entry.byteSize == image.storedBytes)
        #expect(entry.previewText == "PNG 640 × 480")
        #expect(store.currentEntryID == id)
        #expect(store.entries.map(\.kind) == [.image, .text])
    }

    @Test(arguments: Store.allCases)
    func completingAnImageAnotherEntryHoldsMakesThemOneAtTheNewerCopy(store kind: Store) throws {
        let store = makeStore(kind)
        let earlier = try saved(1)
        store.record(.image(earlier), sourceApp: nil, at: start)
        store.record(text: "between", sourceApp: nil, at: start + 1)
        let pending = unsaved()
        let id = store.record(.image(pending), sourceApp: safari, at: start + 2)

        // The newer copy turned out to be the same image: it was not written again.
        store.completeImage(pending, with: earlier, keepsEarlierCopy: false)

        #expect(store.entries.map(\.kind) == [.image, .text])
        let entry = try #require(store.entries.first)
        #expect(entry.id == id)
        #expect(entry.content == .image(earlier))
        #expect(entry.date == start + 2)
        #expect(entry.sourceApp == safari)
        #expect(store.currentEntryID == id)
        #expect(blobs.allIDs() == Set(earlier.blobIDs))
    }

    @Test(arguments: Store.allCases)
    func sameImageSavedTwiceKeepsTheNewerData(store kind: Store) throws {
        let store = makeStore(kind)
        let first = unsaved()
        let second = unsaved()
        store.record(.image(first), sourceApp: nil, at: start)
        let id = store.record(.image(second), sourceApp: nil, at: start + 1)
        let firstImage = try saved(as: first)
        let secondImage = try saved(as: second)

        store.completeImage(first, with: firstImage, keepsEarlierCopy: false)
        store.completeImage(second, with: secondImage, keepsEarlierCopy: false)

        #expect(store.entries.map(\.id) == [id])
        #expect(store.entries.first?.content == .image(secondImage))
        #expect(blobs.allIDs() == Set(secondImage.blobIDs))
    }

    @Test(arguments: Store.allCases)
    func imageFoundAtLaunchKeepsTheEntryItRepeats(store kind: Store) throws {
        let store = makeStore(kind)
        let earlier = try saved(1)
        let earlierID = store.record(.image(earlier), sourceApp: safari, at: start)
        store.markCurrentSkipped()
        let pending = unsaved()
        store.record(.image(pending), sourceApp: nil, at: start + 100)

        store.completeImage(pending, with: earlier, keepsEarlierCopy: true)

        let entry = try #require(store.entries.first)
        #expect(store.entries.count == 1)
        #expect(entry.id == earlierID)
        #expect(entry.date == start)
        #expect(entry.sourceApp == safari)
        #expect(store.currentEntryID == earlierID)
    }

    @Test(arguments: Store.allCases)
    func keepingTheEarlierCopyAppliesOnlyToTheEntryJustBelow(store kind: Store) throws {
        let store = makeStore(kind)
        let earlier = try saved(1)
        store.record(.image(earlier), sourceApp: safari, at: start)
        store.record(text: "between", sourceApp: nil, at: start + 1)
        let pending = unsaved()
        let id = store.record(.image(pending), sourceApp: nil, at: start + 100)

        store.completeImage(pending, with: earlier, keepsEarlierCopy: true)

        #expect(store.entries.map(\.kind) == [.image, .text])
        #expect(store.entries.first?.id == id)
        #expect(store.entries.first?.date == start + 100)
    }

    @Test(arguments: Store.allCases)
    func imageWhoseEntryIsGoneHasItsNewBlobsDeleted(store kind: Store) throws {
        let store = makeStore(kind)
        let kept = try saved(1)
        store.record(.image(kept), sourceApp: nil, at: start)
        let pending = unsaved()
        let id = store.record(.image(pending), sourceApp: nil, at: start + 1)
        store.remove(id: id)

        store.completeImage(pending, with: try saved(2, as: pending), keepsEarlierCopy: false)
        // A result that reuses an image another entry holds leaves that image alone.
        store.completeImage(pending, with: kept, keepsEarlierCopy: false)

        #expect(store.entries.map(\.content) == [.image(kept)])
        #expect(blobs.allIDs() == Set(kept.blobIDs))
    }

    @Test func unsavedImageIsKeptInMemoryOnlyUntilItIsComplete() throws {
        let store = makeStore(.persistent)
        let pending = unsaved()
        let id = store.record(.image(pending), sourceApp: nil, at: start)
        #expect(disk.record(id) == nil)

        let image = try saved(as: pending)
        store.completeImage(pending, with: image, keepsEarlierCopy: false)
        #expect(disk.record(id)?.blobIDs == image.blobIDs.map(\.uuid))
    }
}
