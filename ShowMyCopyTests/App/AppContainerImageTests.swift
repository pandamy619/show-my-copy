import AppKit
import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct AppContainerImageTests {
    private let pasteboard = FakePasteboard()
    private let base = InMemoryBlobStore()
    private let blobs: InFlightBlobStore
    private let decoder = FakeImageDecoder()

    init() {
        blobs = InFlightBlobStore(base: base)
    }

    private func makeContainer(
        store: any HistoryStore,
        blobs: InFlightBlobStore?,
        defaults: UserDefaults,
        thumbnails: FakeThumbnailMaker = FakeThumbnailMaker(),
        fileThumbnails: (any FileThumbnailMaking)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = MonitorFactory.sleepUntilCancelled
    ) -> AppContainer {
        let media = AppServices.Media(
            blobs: blobs, thumbnails: thumbnails, fileThumbnails: fileThumbnails, previewImages: decoder)
        return AppContainer(
            history: .unsaved(store),
            services: ContainerFactory.services(pasteboard: pasteboard, sleep: sleep, media: media),
            defaults: defaults)
    }

    @Test func copiedPhotoFilesGetThumbnailsInTheBlobStore() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let store = InMemoryHistoryStore(blobs: blobs)
            let container = makeContainer(
                store: store, blobs: blobs, defaults: defaults, fileThumbnails: FakeFileThumbnailMaker())
            pasteboard.copyFiles([URL(filePath: "/Users/me/a.jpg")])
            container.monitor.poll()
            await container.monitor.finishEnriching()
            let entry = try #require(store.entries.first)
            #expect(entry.content.blobIDs.count == 1)
            #expect(base.allIDs() == Set(entry.content.blobIDs))
        }
    }

    /// The window deletes in the blob store the history and the background work share, so Undo brings an image back
    /// with its data and closing the window deletes it.
    @Test func deletedImageComesBackWithUndoAndItsDataGoesWhenTheWindowCloses() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let store = InMemoryHistoryStore(blobs: blobs)
            let container = makeContainer(store: store, blobs: blobs, defaults: defaults)
            pasteboard.copy([.png: Data([0x89, 0x50])])
            container.monitor.poll()
            await container.monitor.finishEnriching()
            let image = try #require(store.entries.first)
            let window = container.historyWindow
            window.show()

            #expect(window.handleCommandKey(.delete))
            #expect(store.entries.isEmpty)
            #expect(pasteboard.text == nil && pasteboard.types.isEmpty)
            #expect(window.handleCommandKey(.undo))
            #expect(store.entries == [image])
            #expect(base.allIDs() == Set(image.content.blobIDs))

            #expect(window.handleCommandKey(.delete))
            window.hide()
            #expect(base.allIDs().isEmpty)
        }
    }

    @Test func withoutABlobStoreFilesGetNoThumbnails() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let store = InMemoryHistoryStore()
            let maker = FakeFileThumbnailMaker()
            let container = makeContainer(store: store, blobs: nil, defaults: defaults, fileThumbnails: maker)
            pasteboard.copyFiles([URL(filePath: "/Users/me/a.jpg")])
            container.monitor.poll()
            #expect(store.entries.first?.content.blobIDs == [])
            #expect(maker.askedNames.isEmpty)
        }
    }

    @Test func imagesAreStoredInTheBlobStoreAndCopiedBack() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let store = InMemoryHistoryStore(blobs: blobs)
            let container = makeContainer(store: store, blobs: blobs, defaults: defaults)
            pasteboard.copy([.png: Data([0x89, 0x50])])
            container.monitor.poll()
            await container.monitor.finishEnriching()
            let entry = try #require(store.entries.first)
            #expect(entry.kind == .image)

            pasteboard.copy("text")
            container.monitor.poll()
            #expect(container.copier.copy(entry))
            #expect(pasteboard.writtenPayloads == [.image(Data([0x89, 0x50]), typeIdentifier: "public.png")])
        }
    }

    @Test func historyWindowReadsThumbnailsAndFullImagesFromTheBlobStore() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let store = InMemoryHistoryStore(blobs: blobs)
            let container = makeContainer(store: store, blobs: blobs, defaults: defaults)
            pasteboard.copy([.png: Data([0x89, 0x50])])
            container.monitor.poll()
            await container.monitor.finishEnriching()
            let entry = try #require(store.entries.first)
            let image = try #require(entry.content.image)
            let model = container.historyWindow.model

            let thumbnail = try #require(await model.thumbnails.thumbnail(for: image) as? FakePreviewImage)
            #expect(thumbnail.data == Data(repeating: 0x89, count: 100))

            model.showPreview(of: entry)
            await model.preview.pendingLoad?.value
            guard case .image(_, .loaded(let full)) = model.preview.content else {
                Issue.record("expected the full image")
                return
            }
            #expect((full as? FakePreviewImage)?.data == Data([0x89, 0x50]))
        }
    }

    @Test func withoutABlobStoreImagesAreNotRead() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let store = InMemoryHistoryStore()
            let container = makeContainer(store: store, blobs: nil, defaults: defaults)
            pasteboard.copy([.png: Data([0x89, 0x50])])
            container.monitor.poll()
            await container.monitor.finishEnriching()
            #expect(store.entries.isEmpty)
        }
    }

    @Test func quittingWaitsUntilAnImageBeingSavedIsInTheHistory() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let gate = AsyncGate()
            let store = InMemoryHistoryStore(blobs: blobs)
            let container = makeContainer(
                store: store, blobs: blobs, defaults: defaults, thumbnails: FakeThumbnailMaker(gate: gate))
            #expect(!container.isCapturing)
            gate.arm()
            pasteboard.copy([.png: Data([0x89, 0x50])])
            container.monitor.poll()
            await gate.waitUntilReached()
            #expect(container.isCapturing)

            let quitting = Task { await container.finishCapturing(within: AppContainer.quitBudget) }
            gate.open()
            await quitting.value
            #expect(!container.isCapturing)
            #expect(store.entries.first?.content.image?.isSaved == true)
        }
    }

    @Test func quittingWaitsNoLongerThanTheBudget() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let gate = AsyncGate()
            let timers = ManualTimers()
            let store = InMemoryHistoryStore(blobs: blobs)
            let container = makeContainer(
                store: store, blobs: blobs, defaults: defaults, thumbnails: FakeThumbnailMaker(gate: gate),
                sleep: timers.sleep)
            gate.arm()
            pasteboard.copy([.png: Data([0x89, 0x50])])
            container.monitor.poll()
            await gate.waitUntilReached()

            let quitting = Task { await container.finishCapturing(within: AppContainer.quitBudget) }
            await timers.waitForSleep(of: AppContainer.quitBudget)
            timers.fire(AppContainer.quitBudget)
            await quitting.value
            #expect(container.isCapturing)

            gate.open()
            await container.monitor.finishEnriching()
        }
    }

    @Test func quittingWithNothingBeingSavedDoesNotWait() async throws {
        try await ContainerFactory.withDefaults { defaults in
            let container = makeContainer(store: InMemoryHistoryStore(blobs: blobs), blobs: blobs, defaults: defaults)
            await container.finishCapturing(within: AppContainer.quitBudget)
            #expect(AppContainer.quitBudget == .seconds(2))
        }
    }
}
