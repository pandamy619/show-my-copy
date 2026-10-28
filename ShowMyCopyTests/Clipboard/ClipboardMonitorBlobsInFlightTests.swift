import Foundation
import Testing

@testable import ShowMyCopy

/// Clear History, the limits and the sweep at launch run while an image or thumbnails are being saved in the
/// background. They must never delete what that work is about to hand to the history, and what it hands to an entry
/// that is gone must be deleted.
@MainActor
struct ClipboardMonitorBlobsInFlightTests {
    private let pasteboard = FakePasteboard()
    private let base = InMemoryBlobStore()
    private let blobs: InFlightBlobStore
    private let disk = FakeHistoryPersistence()
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 7, 7])
    /// Holds saving an image before anything is written, when armed.
    private let imageGate = AsyncGate()
    /// Holds making a file thumbnail, when armed, and with it the work for every later copy.
    private let fileGate = AsyncGate()

    init() {
        blobs = InFlightBlobStore(base: base)
    }

    private func makeStore() -> PersistentHistoryStore {
        PersistentHistoryStore.loadedNow(persistence: disk, sealer: nil, savesPasswords: false, blobs: blobs)
    }

    private func makeMonitor(history: any HistoryStore) -> ClipboardMonitor {
        MonitorFactory.make(
            pasteboard: pasteboard, history: history, blobs: blobs,
            imageIngestor: ImageIngestor(thumbnails: FakeThumbnailMaker(gate: imageGate)),
            fileThumbnailIngestor: FileThumbnailIngestor(
                maker: FakeFileThumbnailMaker(gate: fileGate), sleep: ManualTimers().sleep))
    }

    @Test func clearHistoryWhileAnImageIsSavedLeavesNoBrokenEntryAndNoBlobs() async {
        let store = makeStore()
        let monitor = makeMonitor(history: store)
        monitor.poll()
        imageGate.arm()
        pasteboard.copy([.png: png])
        monitor.poll()
        await imageGate.waitUntilReached()

        store.clear()
        imageGate.open()
        await monitor.finishEnriching()
        #expect(store.entries.isEmpty)
        expectEveryBlobBelongsToAnEntry(of: store, in: base)
    }

    @Test func clearHistoryKeepsWhatWorkInFlightHasWrittenUntilItIsHandedOn() throws {
        let store = makeStore()
        let reservation = blobs.reservation()
        let written = try reservation.write(Data([1]))
        let settled = try blobs.write(Data([2]))

        store.clear()
        #expect(base.allIDs() == [written])
        #expect(reservation.release() == [written])
        #expect(!base.contains(settled))
    }

    @Test func limitsWhileAnImageIsCopiedAgainKeepTheDataItReuses() async throws {
        let store = makeStore()
        let monitor = makeMonitor(history: store)
        monitor.poll()
        pasteboard.copy([.png: png])
        monitor.poll()
        await monitor.finishEnriching()
        for index in 0..<10 {
            pasteboard.copy("text \(index)")
            monitor.poll()
        }
        // Thumbnails of a copied photo take a while, so the work for the next copy waits.
        fileGate.arm()
        pasteboard.copyFiles([URL(filePath: "/Users/me/photo.jpg")])
        monitor.poll()
        await fileGate.waitUntilReached()

        // The same image is copied again. Before it is recognized, a lower limit removes its first entry.
        pasteboard.copy([.png: png])
        monitor.poll()
        store.setLimit(10)
        fileGate.open()
        await monitor.finishEnriching()

        let image = try #require(store.entries.first?.content.image)
        #expect(image.isSaved)
        #expect(try blobs.read(image.blobID) == png)
        #expect(store.entries.filter { $0.kind == .image }.count == 1)
        expectEveryBlobBelongsToAnEntry(of: store, in: base)
    }

    @Test func sweepAtLaunchKeepsTheBlobsOfWorkInFlight() throws {
        let reservation = blobs.reservation()
        let id = try reservation.write(Data([1]))

        // Opening the history deletes the blobs no saved record uses, except those still being handed on.
        _ = makeStore()
        #expect(base.contains(id))
        #expect(reservation.release() == [id])
    }
}
