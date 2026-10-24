import Foundation
import Synchronization
import Testing

@testable import ShowMyCopy

/// Makes file thumbnails from the file name alone: "*.jpg" and "*.png" are photos, "*.mov" videos. A name with
/// "slow" never finishes until it is cancelled, one with "broken" gives no thumbnail. Counts what it was asked.
final class FakeFileThumbnailMaker: FileThumbnailMaking {
    private let asked = Mutex<[String]>([])
    private let made = Mutex<[String]>([])
    private let started = Mutex<(names: Set<String>, waiters: [(String, CheckedContinuation<Void, Never>)])>(([], []))
    private let pixelSize: Int

    init(pixelSize: Int = 256) {
        self.pixelSize = pixelSize
    }

    /// The names whose kind was asked for, in order.
    var askedNames: [String] {
        asked.withLock { $0 }
    }

    /// The names whose thumbnail was asked for, in order.
    var thumbnailNames: [String] {
        made.withLock { $0 }
    }

    func mediaKind(of url: URL) -> FileThumbnail.Kind? {
        asked.withLock { $0.append(url.lastPathComponent) }
        switch url.pathExtension {
        case "jpg", "png":
            return .image
        case "mov":
            return .movie
        default:
            return nil
        }
    }

    /// Waits until the thumbnail of the file called `name` is asked for.
    func waitUntilAsked(for name: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isAsked = started.withLock { started in
                guard started.names.contains(name) else {
                    started.waiters.append((name, continuation))
                    return false
                }
                return true
            }
            if isAsked {
                continuation.resume()
            }
        }
    }

    func thumbnail(of url: URL, maximumPixelSize: Int) async -> ImageInspection.Thumbnail? {
        let name = url.lastPathComponent
        made.withLock { $0.append(name) }
        let waiting = started.withLock { started in
            started.names.insert(name)
            let waiting = started.waiters.filter { $0.0 == name }.map(\.1)
            started.waiters.removeAll { $0.0 == name }
            return waiting
        }
        for waiter in waiting {
            waiter.resume()
        }
        if name.contains("slow") {
            // Until the time limit cancels it.
            await suspendUntilCancelled()
            return nil
        }
        if name.contains("broken") {
            return nil
        }
        return ImageInspection.Thumbnail(
            pngData: Data("png of \(name)".utf8), pixelWidth: pixelSize, pixelHeight: pixelSize / 2)
    }
}

struct FileThumbnailIngestorTests {
    private let blobs = CountingBlobStore()
    private let maker = FakeFileThumbnailMaker()
    /// The time limits end only when a test fires them.
    private let timers = ManualTimers()

    /// An ingestor that writes through a new reservation of `blobs` on every call, as the app does.
    private struct Ingesting: Sendable {
        let ingestor: FileThumbnailIngestor
        let blobs: InFlightBlobStore

        func ingest(_ files: [FileReference]) async -> [FileReference] {
            await ingestor.ingest(files, reservation: blobs.reservation())
        }
    }

    private func ingestor(
        maker: (any FileThumbnailMaking)? = nil,
        blobs: (any BlobStore)? = nil,
        maximumFiles: Int = 4,
        timeoutPerFile: Duration = .seconds(10),
        totalBudget: Duration = .seconds(10)
    ) -> Ingesting {
        let ingestor = FileThumbnailIngestor(
            maker: maker ?? self.maker,
            limits: FileThumbnailIngestor.Limits(
                maximumFiles: maximumFiles, timeoutPerFile: timeoutPerFile, totalBudget: totalBudget),
            sleep: timers.sleep)
        return Ingesting(ingestor: ingestor, blobs: InFlightBlobStore(base: blobs ?? self.blobs))
    }

    private func files(_ names: String...) -> [FileReference] {
        names.map { ContentFixtures.file("/Users/me/\($0)") }
    }

    @Test func photosAndVideosGetThumbnailsInTheBlobStore() async throws {
        let copied = files("a.jpg", "b.txt", "c.mov")
        let result = await ingestor().ingest(copied)

        #expect(result.map(\.path) == copied.map(\.path))
        #expect(result.map(\.byteSize) == copied.map(\.byteSize))
        let photo = try #require(result[0].thumbnail)
        #expect(photo.kind == .image)
        #expect(try blobs.read(photo.blobID) == Data("png of a.jpg".utf8))
        #expect(photo.reference.pixelWidth == 256)
        #expect(photo.reference.pixelHeight == 128)
        #expect(photo.reference.byteSize == Data("png of a.jpg".utf8).count)
        #expect(result[1].thumbnail == nil)
        #expect(result[2].thumbnail?.kind == .movie)
        #expect(blobs.allIDs().count == 2)
        #expect(maker.thumbnailNames == ["a.jpg", "c.mov"])
    }

    @Test func onlyTheFirstFilesAreLookedAt() async {
        let copied = files("1.jpg", "2.jpg", "3.jpg", "4.jpg", "5.jpg", "6.jpg")
        let result = await ingestor(maximumFiles: 4).ingest(copied)
        #expect(result.map { $0.thumbnail != nil } == [true, true, true, true, false, false])
        #expect(maker.askedNames == ["1.jpg", "2.jpg", "3.jpg", "4.jpg"])
        #expect(blobs.writeCount == 4)
    }

    @Test func filesAreDoneOneAfterAnotherInTheirOrder() async {
        let result = await ingestor().ingest(files("c.mov", "a.jpg", "b.png"))
        #expect(maker.thumbnailNames == ["c.mov", "a.jpg", "b.png"])
        #expect(result.map(\.name) == ["c.mov", "a.jpg", "b.png"])
    }

    @Test func filesThatHaveAThumbnailAreSkippedAndOnlyNewThumbnailsAreReturned() async {
        let existing = ContentFixtures.fileWithThumbnail("/Users/me/a.jpg")
        let copied = [existing, ContentFixtures.file("/Users/me/b.jpg")]
        let result = await ingestor().ingest(copied)
        #expect(maker.askedNames == ["b.jpg"])
        // The thumbnail the file had is not returned, so discarding the result never deletes it.
        #expect(result[0] == existing.withThumbnail(nil))
        #expect(result[1].thumbnail != nil)
        #expect(blobs.writeCount == 1)
    }

    @Test func standardLimitsKeepTheWaitShort() {
        let limits = FileThumbnailIngestor.Limits.standard
        #expect(limits.maximumFiles == 4)
        #expect(limits.timeoutPerFile == .milliseconds(1500))
        #expect(limits.totalBudget == .seconds(2))
    }

    @Test func urlsThatAreNotFileURLsAreNeverLookedAt() async throws {
        let remote = FileReference(url: try #require(URL(string: "https://example.com/a.jpg")))
        let result = await ingestor().ingest([remote])
        #expect(result == [remote])
        #expect(maker.askedNames.isEmpty)
        #expect(blobs.writeCount == 0)
    }

    @Test func fileThatTakesTooLongKeepsItsIcon() async {
        let ingestor = ingestor(timeoutPerFile: .milliseconds(200))
        let copied = files("slow.mov", "fast.jpg")
        let ingesting = Task { await ingestor.ingest(copied) }
        await maker.waitUntilAsked(for: "slow.mov")
        await timers.waitForSleep(of: .milliseconds(200))
        timers.fire(.milliseconds(200))

        let result = await ingesting.value
        #expect(result[0].thumbnail == nil)
        #expect(result[1].thumbnail != nil)
        #expect(blobs.writeCount == 1)
    }

    @Test func filesLeftWhenTheTimeIsUpKeepTheirIcons() async {
        let ingestor = ingestor(totalBudget: .milliseconds(200))
        let copied = files("a.jpg", "slow.mov", "c.jpg")
        let ingesting = Task { await ingestor.ingest(copied) }
        await maker.waitUntilAsked(for: "slow.mov")
        await timers.waitForSleep(of: .milliseconds(200))
        timers.fire(.milliseconds(200))

        let result = await ingesting.value
        #expect(result.map { $0.thumbnail != nil } == [true, false, false])
        // The third file is not even asked for.
        #expect(maker.thumbnailNames == ["a.jpg", "slow.mov"])
        #expect(blobs.writeCount == 1)
    }

    @Test func fileWithoutAThumbnailKeepsItsIcon() async {
        let result = await ingestor().ingest(files("broken.jpg", "b.jpg"))
        #expect(result[0].thumbnail == nil)
        #expect(result[1].thumbnail != nil)
    }

    @Test func thumbnailsLargerThanAThumbnailAreNotKept() async {
        let large = FakeFileThumbnailMaker(pixelSize: ThumbnailReference.maximumPixelSize * 2)
        let result = await ingestor(maker: large).ingest(files("a.jpg"))
        #expect(result[0].thumbnail == nil)
        #expect(blobs.writeCount == 0)
    }

    @Test func thumbnailsAreChecked() {
        let png = Data([1])
        #expect(FileThumbnailIngestor.isValid(ImageInspection.Thumbnail(pngData: png, pixelWidth: 256, pixelHeight: 1)))
        #expect(
            !FileThumbnailIngestor.isValid(ImageInspection.Thumbnail(pngData: Data(), pixelWidth: 9, pixelHeight: 9)))
        #expect(!FileThumbnailIngestor.isValid(ImageInspection.Thumbnail(pngData: png, pixelWidth: 0, pixelHeight: 9)))
        #expect(
            !FileThumbnailIngestor.isValid(ImageInspection.Thumbnail(pngData: png, pixelWidth: 9, pixelHeight: 257)))
    }

    @Test func thumbnailThatCannotBeWrittenIsLeftOut() async {
        let failing = CountingBlobStore(failingWrite: 1)
        let result = await ingestor(blobs: failing).ingest(files("a.jpg", "b.jpg"))
        #expect(result.allSatisfy { $0.thumbnail == nil })
        #expect(failing.allIDs().isEmpty)
    }

    @Test func theThumbnailsAreHeldUntilTheReservationIsReleased() async throws {
        let inFlight = InFlightBlobStore(base: blobs)
        let reservation = inFlight.reservation()
        let result = await ingestor().ingestor.ingest(files("a.jpg", "b.txt", "c.mov"), reservation: reservation)
        let made = Set(result.compactMap(\.thumbnail?.blobID))
        #expect(made.count == 2)
        #expect(try inFlight.allIDs().isEmpty)
        #expect(Set(reservation.release()) == made)
        #expect(try inFlight.allIDs() == made)
    }

    @Test func runGivesTheResultOrNilAfterTheTimeout() async {
        let sleep = timers.sleep
        #expect(await FileThumbnailIngestor.run(within: .seconds(10), sleep: sleep) { 7 } == 7)
        let running = Task {
            await FileThumbnailIngestor.run(within: .milliseconds(50), sleep: sleep) { () -> Int in
                await suspendUntilCancelled()
                return 7
            }
        }
        await timers.waitForSleep(of: .milliseconds(50))
        timers.fire(.milliseconds(50))
        #expect(await running.value == nil)
    }
}
