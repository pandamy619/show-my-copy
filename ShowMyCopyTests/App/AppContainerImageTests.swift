import AppKit
import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct AppContainerImageTests {
    private let pasteboard = FakePasteboard()
    private let blobs = InMemoryBlobStore()

    private func makeContainer(
        store: any HistoryStore,
        blobs: (any BlobStore)?,
        defaults: UserDefaults
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
            makeSettingsWindow: { _, _, _ in SettingsWindowSpy() }
        )
    }

    private func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let suiteName = "ShowMyCopyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(defaults)
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
