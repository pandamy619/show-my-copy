import Foundation
import Observation
import Testing

@testable import ShowMyCopy

/// What the owner does on a fresh install: the history window is open, or opened right after, when an image or a
/// photo file is copied. The row appears at once, before the image is saved or the photo's thumbnail is made, and
/// must show the thumbnail once the background work hands it to the history, without a relaunch. Runs on a new
/// saved history whose image folder does not exist yet, as at the first launch.
@MainActor
struct ThumbnailAfterCopyTests {
    private let pasteboard = FakePasteboard()
    private let decoder = FakeImageDecoder()
    private let fileThumbnails = FakeFileThumbnailMaker()
    /// The thumbnail `FakeThumbnailMaker` makes of every image.
    private let imageThumbnail = Data(repeating: 0x89, count: 100)
    private let photo = URL(filePath: "/Users/me/photo.jpg")

    /// The parts the app builds at launch, on a new folder.
    private struct App {
        let blobFolder: URL
        let store: PersistentHistoryStore
        let monitor: ClipboardMonitor
        let model: HistoryWindowModel
    }

    /// Builds the history, the monitor and the window model the way `AppContainer` connects them, over a blob folder
    /// that does not exist yet, runs `body`, and removes the folder.
    private func withNewInstall(_ body: @MainActor (App) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "ShowMyCopyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                Issue.record("Could not remove the temporary folder: \(error)")
            }
        }
        let blobFolder = FileBlobStore.directory(inApplicationSupport: folder)
        #expect(!FileManager.default.fileExists(atPath: blobFolder.path(percentEncoded: false)))
        let blobs = InFlightBlobStore(base: MeasuredBlobStore(base: try FileBlobStore(directory: blobFolder)))
        let store = PersistentHistoryStore.loadedNow(
            persistence: InMemoryHistoryPersistence(), sealer: nil, savesPasswords: false, blobs: blobs)
        let monitor = MonitorFactory.make(
            pasteboard: pasteboard, history: store, blobs: blobs,
            imageIngestor: ImageIngestor(thumbnails: FakeThumbnailMaker()),
            fileThumbnailIngestor: FileThumbnailIngestor(
                maker: fileThumbnails, paths: CopiedPaths(volumes: FakeVolumes.startupDiskOnly),
                sleep: MonitorFactory.sleepUntilCancelled))
        let model = HistoryWindowModel(
            history: store, deleter: EntryDeleterSpy(history: store),
            previews: PreviewServices(blobs: blobs, images: decoder, fileAvailability: FakeAvailabilityChecker()))
        try await body(App(blobFolder: blobFolder, store: store, monitor: monitor, model: model))
    }

    /// Whether the rows the window lists change by the time `body` is done.
    private func listChanges(of model: HistoryWindowModel, during body: () async -> Void) async -> Bool {
        let changed = ChangeFlag()
        withObservationTracking {
            _ = model.items
        } onChange: {
            changed.set()
        }
        await body()
        return changed.value
    }

    private func blobExists(_ id: BlobID, in app: App) -> Bool {
        FileManager.default.fileExists(
            atPath: app.blobFolder.appending(path: id.uuid.uuidString).path(percentEncoded: false))
    }

    // MARK: - Images

    @Test func imageCopiedWhileTheWindowIsOpenGetsItsThumbnailInTheSameRow() async throws {
        try await withNewInstall { app in
            app.model.prepareForPresentation()
            pasteboard.copyImage()
            app.monitor.poll()
            let row = try #require(app.model.items.first)
            let recorded = try #require(row.content.image)
            #expect(!recorded.isSaved)
            #expect(app.model.thumbnails.state(for: recorded).isLoading)

            #expect(await listChanges(of: app.model) { await app.monitor.finishEnriching() })
            let completed = try #require(app.model.items.first)
            #expect(completed.id == row.id)
            let saved = try #require(completed.content.image)
            let thumbnail = try #require(saved.thumbnail)
            #expect(saved.isSaved)
            #expect(blobExists(thumbnail.blobID, in: app))

            let loaded = try #require(await app.model.thumbnails.thumbnail(for: saved) as? FakePreviewImage)
            #expect(loaded.data == imageThumbnail)
            #expect(app.model.thumbnails.state(for: saved).value != nil)
        }
    }

    @Test func imageCopiedRightBeforeTheWindowOpensGetsItsThumbnail() async throws {
        try await withNewInstall { app in
            pasteboard.copyImage()
            // Opening the window catches up with the pasteboard first (`HistoryWindowController.show()`).
            app.monitor.poll()
            app.model.prepareForPresentation()
            let recorded = try #require(app.model.selectedEntry?.content.image)
            #expect(app.model.thumbnails.state(for: recorded).isLoading)

            await app.monitor.finishEnriching()
            let saved = try #require(app.model.selectedEntry?.content.image)
            #expect(await app.model.thumbnails.thumbnail(for: saved) != nil)
            #expect(app.model.thumbnails.state(for: saved).value != nil)
        }
    }

    @Test func previewOfAnImageStillBeingSavedStaysLoaded() async throws {
        try await withNewInstall { app in
            pasteboard.copyImage()
            app.monitor.poll()
            app.model.prepareForPresentation()
            #expect(app.model.handleKey(.right, isCaretAtEnd: true) == .handled)
            await app.model.preview.pendingLoad?.value
            guard case .image(_, .loaded) = app.model.preview.content else {
                Issue.record("expected the image read while it is being saved")
                return
            }

            await app.monitor.finishEnriching()
            let completed = try #require(app.model.previewedEntry)
            app.model.showPreview(of: completed)
            await app.model.preview.pendingLoad?.value
            guard case .image(let shown, .loaded) = app.model.preview.content else {
                Issue.record("expected the saved image")
                return
            }
            #expect(shown == completed.content.image)
        }
    }

    // MARK: - Photo and video files

    @Test func photoFileCopiedWhileTheWindowIsOpenGetsItsThumbnailInTheSameRow() async throws {
        try await withNewInstall { app in
            app.model.prepareForPresentation()
            pasteboard.copyFiles([photo])
            app.monitor.poll()
            let row = try #require(app.model.items.first)
            guard case .files(let recorded) = row.content else {
                Issue.record("expected files")
                return
            }
            #expect(recorded.first?.thumbnail == nil)

            #expect(await listChanges(of: app.model) { await app.monitor.finishEnriching() })
            let completed = try #require(app.model.items.first)
            #expect(completed.id == row.id)
            guard case .files(let files) = completed.content else {
                Issue.record("expected files")
                return
            }
            let thumbnail = try #require(files.first?.thumbnail)
            #expect(blobExists(thumbnail.blobID, in: app))
            #expect(app.model.thumbnails.state(for: thumbnail).isLoading)
            #expect(await app.model.thumbnails.thumbnail(for: thumbnail) != nil)
            #expect(app.model.thumbnails.state(for: thumbnail).value != nil)
        }
    }

    /// → opened on the files before their thumbnails were made shows them once they are, as the row does.
    @Test func previewOfPhotoFilesShowsTheThumbnailsMadeAfterItOpened() async throws {
        try await withNewInstall { app in
            pasteboard.copyFiles([photo])
            app.monitor.poll()
            app.model.prepareForPresentation()
            #expect(app.model.handleKey(.right, isCaretAtEnd: true) == .handled)
            guard case .files(let before) = app.model.preview.content else {
                Issue.record("expected files")
                return
            }
            #expect(before.first?.thumbnail == nil)

            await app.monitor.finishEnriching()
            await app.model.preview.pendingLoad?.value
            let completed = try #require(app.model.previewedEntry)
            app.model.showPreview(of: completed)
            await app.model.preview.pendingLoad?.value
            guard case .files(let items) = app.model.preview.content, case .files(let files) = completed.content else {
                Issue.record("expected files")
                return
            }
            #expect(files.first?.thumbnail != nil)
            #expect(items.map(\.thumbnail) == files.map(\.thumbnail))
            #expect(items.first?.availability == .available)
        }
    }
}
