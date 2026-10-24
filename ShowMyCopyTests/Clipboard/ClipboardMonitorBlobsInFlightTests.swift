import Foundation
import Testing

@testable import ShowMyCopy

/// Clear History, the limits and the sweep at launch run while an image or thumbnails are being saved in the
/// background. They must never delete what that work is about to hand to the history, and what it hands to an entry
/// that is gone must be deleted.
@MainActor
struct ClipboardMonitorBlobsInFlightTests {
    private let pasteboard = FakePasteboard()
    private let base = GatedBlobStore()
    private let blobs: InFlightBlobStore
    private let disk = FakeHistoryPersistence()
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 7, 7])

    init() {
        blobs = InFlightBlobStore(base: base)
    }

    private func makeStore() -> PersistentHistoryStore {
        PersistentHistoryStore(persistence: disk, sealer: nil, savesPasswords: false, blobs: blobs)
    }

    private func makeMonitor(
        history: any HistoryStore, hasher: any ContentHasher = SHA256ContentHasher()
    ) -> ClipboardMonitor {
        MonitorFactory.make(
            pasteboard: pasteboard, history: history, blobs: blobs,
            imageIngestor: ImageIngestor(thumbnails: FakeThumbnailMaker(), hasher: hasher))
    }

    /// Every blob an entry names is stored, and every stored blob belongs to an entry.
    private func expectEveryBlobBelongsToAnEntry(_ history: any HistoryStore) {
        let used = Set(history.entries.flatMap(\.content.blobIDs))
        #expect(used.allSatisfy { base.contains($0) })
        #expect(base.allIDs() == used)
    }

    @Test func clearHistoryWhileAnImageIsSavedLeavesNoBrokenEntry() async {
        let store = makeStore()
        let monitor = makeMonitor(history: store)
        monitor.poll()
        // The image data and its thumbnail are written, and the work stops before it hands them on.
        base.stop(afterWrites: 2)
        pasteboard.copy([.png: png])
        monitor.poll()
        await base.gate.waitUntilReached()

        store.clear()
        base.gate.open()
        await monitor.finishStoringImages()
        expectEveryBlobBelongsToAnEntry(store)
    }

    @Test func limitsWhileAnImageIsCopiedAgainKeepTheDataItReuses() async throws {
        let gate = BlockingGate()
        let store = makeStore()
        let monitor = makeMonitor(history: store, hasher: GatedHasher(gate: gate))
        monitor.poll()
        pasteboard.copy([.png: png])
        monitor.poll()
        await monitor.finishStoringImages()
        for index in 0..<10 {
            pasteboard.copy("text \(index)")
            monitor.poll()
        }

        // The same image is copied again. While it is recognized, a lower limit removes its first entry.
        gate.arm()
        pasteboard.copy([.png: png])
        monitor.poll()
        await gate.waitUntilReached()
        store.setLimit(10)
        gate.open()
        await monitor.finishStoringImages()

        let image = try #require(store.entries.first?.content.image)
        #expect(try blobs.read(image.blobID) == png)
        #expect(store.entries.filter { $0.kind == .image }.count == 1)
        expectEveryBlobBelongsToAnEntry(store)
    }

    @Test func sweepAtLaunchKeepsTheBlobsOfWorkInFlight() throws {
        let reservation = blobs.reservation()
        let id = reservation.newID()
        try blobs.write(Data([1]), as: id)

        // Opening the history deletes the blobs no saved record uses, except those still being handed on.
        _ = makeStore()
        #expect(base.contains(id))
        #expect(reservation.release() == [id])
    }
}
