import Foundation
import Synchronization
import Testing

@testable import ShowMyCopy

/// The names of the files whose size was read, from any thread.
final class AskedNames: Sendable {
    private let names = Mutex<[String]>([])

    var all: [String] {
        names.withLock { $0 }
    }

    func append(_ name: String) {
        names.withLock { $0.append(name) }
    }
}

/// Copied files are recorded without sizes; their sizes are read afterwards, off the main actor.
struct FileSizeReaderTests {
    private let timers = ManualTimers()
    private let asked = AskedNames()
    private let volumes = FakeVolumes([
        MountedVolume(mountPoint: "/", fileSystem: "apfs", isLocal: true),
        MountedVolume(mountPoint: "/Volumes/share", fileSystem: "smbfs", isLocal: false),
    ])

    private func reader(gate: AsyncGate? = nil) -> FileSizeReader {
        FileSizeReader(
            paths: CopiedPaths(volumes: volumes),
            size: { [asked] url in
                asked.append(url.lastPathComponent)
                await gate?.pass()
                return url.lastPathComponent.hasPrefix("folder") ? nil : url.lastPathComponent.count * 100
            },
            sleep: timers.sleep)
    }

    @Test func readsTheSizesOfLocalFiles() async {
        let files = [
            ContentFixtures.file("/Users/me/a.txt", byteSize: nil),
            ContentFixtures.file("/Users/me/folder", byteSize: nil),
        ]
        let result = await reader().sizes(of: files)
        #expect(result.map(\.byteSize) == [500, nil])
        #expect(result.map(\.path) == files.map(\.path))
    }

    @Test func neverLooksAtFilesOnNetworkVolumesOrAutomountedPaths() async {
        let files = [
            ContentFixtures.file("/Volumes/share/a.txt", byteSize: nil),
            ContentFixtures.file("/net/host/b.txt", byteSize: nil),
            ContentFixtures.file("/Users/me/c.txt", byteSize: nil),
        ]
        let result = await reader().sizes(of: files)
        #expect(result.map(\.byteSize) == [nil, nil, 500])
        #expect(asked.all == ["c.txt"])
    }

    @Test func keepsSizesThatAreKnown() async {
        let known = FileReference(url: URL(filePath: "/Users/me/a.txt"), byteSize: 42)
        let result = await reader().sizes(of: [known])
        #expect(result == [known])
        #expect(asked.all.isEmpty)
    }

    @Test func filesNotReadWithinTheBudgetShowNoSize() async {
        let gate = AsyncGate()
        let reader = reader(gate: gate)
        gate.arm()
        let files = [
            ContentFixtures.file("/Users/me/a.txt", byteSize: nil),
            ContentFixtures.file("/Users/me/b.txt", byteSize: nil),
        ]
        let reading = Task { await reader.sizes(of: files) }
        await gate.waitUntilReached()
        await timers.waitForSleep(of: FileSizeReader.budget)
        timers.fire(FileSizeReader.budget)

        #expect(await reading.value.map(\.byteSize) == [nil, nil])
        gate.open()
    }

    @Test func theBudgetIsShort() {
        #expect(FileSizeReader.budget == .seconds(1))
    }
}
