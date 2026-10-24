import AppKit
import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct AppContainerImageTests {
    private let pasteboard = FakePasteboard()
    private let blobs = InMemoryBlobStore()
    private let decoder = FakeImageDecoder()

    private func makeContainer(
        store: any HistoryStore,
        blobs: (any BlobStore)?,
        defaults: UserDefaults,
        fileThumbnails: (any FileThumbnailMaking)? = nil
    ) -> AppContainer {
        AppContainer(
            store: store,
            pasteboard: pasteboard,
            defaults: defaults,
            frontmostApp: { nil },
            pollingActivity: CountingActivity(),
            workspaceNotifications: FakeNotifications(),
            distributedNotifications: FakeNotifications(),
            isScreenLocked: { false },
            isSessionActive: { true },
            blobs: blobs,
            thumbnails: FakeThumbnailMaker(),
            fileThumbnails: fileThumbnails,
            previewImages: decoder,
            makeSettingsWindow: { _, _, _ in SettingsWindowSpy() }
        )
    }

    private func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let suiteName = "ShowMyCopyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(defaults)
    }

    @Test func copiedPhotoFilesGetThumbnailsInTheBlobStore() async throws {
        try await withDefaults { defaults in
            let store = InMemoryHistoryStore(blobs: blobs)
            let container = makeContainer(
                store: store, blobs: blobs, defaults: defaults, fileThumbnails: FakeFileThumbnailMaker())
            pasteboard.copyFiles([URL(filePath: "/Users/me/a.jpg")])
            container.monitor.poll()
            await container.monitor.finishStoringImages()
            let entry = try #require(store.entries.first)
            #expect(entry.content.blobIDs.count == 1)
            #expect(blobs.allIDs() == Set(entry.content.blobIDs))
        }
    }

    @Test func withoutABlobStoreFilesGetNoThumbnails() async throws {
        try await withDefaults { defaults in
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
        try await withDefaults { defaults in
            let store = InMemoryHistoryStore(blobs: blobs)
            let container = makeContainer(store: store, blobs: blobs, defaults: defaults)
            #expect(container.blobs != nil)
            pasteboard.copy([.png: Data([0x89, 0x50])])
            container.monitor.poll()
            await container.monitor.finishStoringImages()
            let entry = try #require(store.entries.first)
            #expect(entry.kind == .image)

            pasteboard.copy("text")
            container.monitor.poll()
            #expect(container.copier.copy(entry))
            #expect(pasteboard.writtenPayloads == [.image(Data([0x89, 0x50]), typeIdentifier: "public.png")])
        }
    }

    @Test func historyWindowReadsThumbnailsAndFullImagesFromTheBlobStore() async throws {
        try await withDefaults { defaults in
            let store = InMemoryHistoryStore(blobs: blobs)
            let container = makeContainer(store: store, blobs: blobs, defaults: defaults)
            pasteboard.copy([.png: Data([0x89, 0x50])])
            container.monitor.poll()
            await container.monitor.finishStoringImages()
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
        try await withDefaults { defaults in
            let store = InMemoryHistoryStore()
            let container = makeContainer(store: store, blobs: nil, defaults: defaults)
            pasteboard.copy([.png: Data([0x89, 0x50])])
            container.monitor.poll()
            await container.monitor.finishStoringImages()
            #expect(store.entries.isEmpty)
        }
    }
}
