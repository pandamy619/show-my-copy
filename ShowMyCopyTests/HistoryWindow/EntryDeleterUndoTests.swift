import Foundation
import Testing

@testable import ShowMyCopy

/// A deleted entry leaves the disk at once, its files when Undo can no longer bring it back, and an image still being
/// saved leaves nothing behind.
@MainActor
struct EntryDeleterUndoTests {
    private let pasteboard = FakePasteboard()
    private let base = InMemoryBlobStore()
    private let blobs: InFlightBlobStore
    private let disk = FakeHistoryPersistence()
    private let store: PersistentHistoryStore
    private let imageGate = AsyncGate()
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 7, 7])
    private let clock = TestClock()
    private let monitor: ClipboardMonitor
    private let deleter: EntryDeleter

    init() {
        blobs = InFlightBlobStore(base: base)
        store = disk.makeStore(now: MonitorFactory.date, blobs: blobs)
        monitor = MonitorFactory.make(
            pasteboard: pasteboard, history: store, now: { [clock] in clock.now },
            passwordPolicy: { PasswordPolicy(savesPasswords: true, lifetime: 600) }, blobs: blobs,
            imageIngestor: ImageIngestor(thumbnails: FakeThumbnailMaker(gate: imageGate)))
        deleter = EntryDeleter(
            history: store, pasteboard: pasteboard, monitor: monitor, blobs: blobs, now: { [clock] in clock.now })
    }

    /// Another app copies an image; it is recorded and saved.
    private func copyImage() async throws -> ClipboardEntry {
        pasteboard.copy([.png: png])
        monitor.poll()
        await monitor.finishEnriching()
        let entry = try #require(store.entries.first)
        #expect(entry.content.image?.isSaved == true)
        return entry
    }

    private func copyText(_ text: String) throws -> ClipboardEntry {
        pasteboard.copy(text)
        monitor.poll()
        return try #require(store.entries.first)
    }

    /// Every blob an entry names is stored, and every stored blob belongs to an entry.
    private func expectEveryBlobBelongsToAnEntry(sourceLocation: SourceLocation = #_sourceLocation) {
        let used = Set(store.entries.flatMap(\.content.blobIDs))
        #expect(used.allSatisfy { base.contains($0) }, sourceLocation: sourceLocation)
        #expect(base.allIDs() == used, sourceLocation: sourceLocation)
    }

    // MARK: - Undo

    @Test func undoBringsBackTheEntryWithItsFilesAndRecord() async throws {
        monitor.poll()
        let image = try await copyImage()
        let text = try copyText("newer")

        deleter.delete(image.id)
        #expect(store.entries.map(\.id) == [text.id])
        #expect(disk.record(image.id) == nil)
        // The files wait for Undo.
        #expect(Set(image.content.blobIDs).isSubset(of: base.allIDs()))

        #expect(deleter.undoDelete() == image.id)
        #expect(store.entries.map(\.id) == [text.id, image.id])
        #expect(store.entries.last == image)
        #expect(disk.record(image.id) != nil)
        #expect(!deleter.canUndoDelete)
        expectEveryBlobBelongsToAnEntry()
    }

    @Test func finishingDeletesTheFiles() async throws {
        monitor.poll()
        let image = try await copyImage()

        deleter.delete(image.id)
        deleter.finishDeleting()

        #expect(store.entries.isEmpty)
        #expect(!deleter.canUndoDelete)
        #expect(deleter.undoDelete() == nil)
        expectEveryBlobBelongsToAnEntry()
    }

    @Test func onlyTheLastDeletedEntryComesBack() async throws {
        monitor.poll()
        let image = try await copyImage()
        let text = try copyText("newer")

        deleter.delete(image.id)
        deleter.delete(text.id)
        // The image's files went with the second deletion.
        expectEveryBlobBelongsToAnEntry()

        #expect(deleter.undoDelete() == text.id)
        #expect(store.entries.map(\.id) == [text.id])
        #expect(deleter.undoDelete() == nil)
    }

    @Test func undoDoesNotPutTheEntryBackOnThePasteboard() throws {
        monitor.poll()
        let current = try copyText("on the clipboard")

        deleter.delete(current.id)
        let writes = pasteboard.writtenPayloads.count
        deleter.undoDelete()

        #expect(store.entries.map(\.id) == [current.id])
        #expect(store.currentEntryID == nil)
        #expect(pasteboard.writtenPayloads.count == writes)
        #expect(pasteboard.text == nil)
    }

    @Test func clearHistoryMeanwhileDoesNotDeleteTheFilesUndoBringsBack() async throws {
        monitor.poll()
        let image = try await copyImage()
        deleter.delete(image.id)

        store.clear()
        #expect(Set(image.content.blobIDs).isSubset(of: base.allIDs()))
        deleter.undoDelete()

        #expect(store.entries.map(\.id) == [image.id])
        expectEveryBlobBelongsToAnEntry()
    }

    @Test func contentCopiedAgainMeanwhileIsNotAddedTwice() throws {
        monitor.poll()
        let deleted = try copyText("again")
        deleter.delete(deleted.id)
        let copiedAgain = try copyText("again")

        #expect(deleter.undoDelete() == copiedAgain.id)
        #expect(store.entries.map(\.id) == [copiedAgain.id])
    }

    @Test func imageCopiedAgainMeanwhileKeepsOnlyTheFilesItUses() async throws {
        monitor.poll()
        let deleted = try await copyImage()
        deleter.delete(deleted.id)
        let copiedAgain = try await copyImage()

        #expect(deleter.undoDelete() == copiedAgain.id)
        #expect(store.entries.map(\.id) == [copiedAgain.id])
        expectEveryBlobBelongsToAnEntry()
    }

    @Test func aPasswordWhoseTimeIsUpDoesNotComeBack() throws {
        monitor.poll()
        pasteboard.copy("hunter2", markers: [PasteboardMarker.concealed])
        monitor.poll()
        let password = try #require(store.entries.first)
        #expect(password.isConcealed)

        deleter.delete(password.id)
        clock.now += 600

        #expect(deleter.undoDelete() == nil)
        #expect(store.entries.isEmpty)
        #expect(disk.records.isEmpty)
    }

    @Test func aPasswordComesBackConcealedWithItsExpiry() throws {
        monitor.poll()
        pasteboard.copy("hunter2", markers: [PasteboardMarker.concealed])
        monitor.poll()
        let password = try #require(store.entries.first)

        deleter.delete(password.id)
        #expect(pasteboard.text == nil)
        clock.now += 60

        #expect(deleter.undoDelete() == password.id)
        let restored = try #require(store.entries.first)
        #expect(restored.isConcealed)
        #expect(restored.expiresAt == password.expiresAt)
        #expect(disk.record(password.id)?.isConcealed == true)
    }

    // MARK: - An image still being saved

    @Test func anImageStillBeingSavedLeavesNothingBehind() async throws {
        monitor.poll()
        imageGate.arm()
        pasteboard.copy([.png: png])
        monitor.poll()
        await imageGate.waitUntilReached()
        let unsaved = try #require(store.entries.first)
        #expect(unsaved.content.image?.isSaved == false)

        deleter.delete(unsaved.id)
        // It was on the pasteboard, as the app recorded it.
        #expect(pasteboard.clearedChangeCounts == [1])
        #expect(!deleter.canUndoDelete)

        imageGate.open()
        await monitor.finishEnriching()
        #expect(store.entries.isEmpty)
        #expect(disk.records.isEmpty)
        expectEveryBlobBelongsToAnEntry()
    }

    @Test func anImageStillBeingSavedThatRepeatsAnEarlierOneKeepsTheEarlierFiles() async throws {
        monitor.poll()
        let earlier = try await copyImage()
        let between = try copyText("between")
        // Copied again: recognized in the background without a thumbnail being made. Deleted before that is done.
        pasteboard.copy([.png: png])
        monitor.poll()
        let unsaved = try #require(store.entries.first)
        #expect(unsaved.content.image?.isSaved == false)
        #expect(monitor.isEnriching)

        deleter.delete(unsaved.id)
        await monitor.finishEnriching()

        // The copy being saved turned out to be the earlier image, whose files stay with it.
        #expect(store.entries.map(\.id) == [between.id, earlier.id])
        #expect(try blobs.read(try #require(earlier.content.image).blobID) == png)
        expectEveryBlobBelongsToAnEntry()
    }
}

/// A clock the test moves by hand.
@MainActor
final class TestClock {
    var now = MonitorFactory.date
}
