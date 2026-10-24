import Foundation
import Testing

@testable import ShowMyCopy

/// The real mount list, read with `getfsstat(MNT_NOWAIT)`.
struct SystemMountedVolumesTests {
    @Test func listsTheStartupDiskAsLocal() throws {
        let volumes = try #require(SystemMountedVolumes().mountedVolumes())
        let root = try #require(volumes.first { $0.mountPoint == "/" })
        #expect(root.isLocal)
        #expect(root.fileSystem == "apfs")
    }

    @Test func placesTheHomeFolderAndTemporaryFilesOnTheStartupDisk() {
        let paths = CopiedPaths()
        #expect(paths.access(for: FileManager.default.homeDirectoryForCurrentUser) == .startupDisk)
        #expect(paths.access(for: FileManager.default.temporaryDirectory) == .startupDisk)
    }

    @Test func neverAllowsAutomountedPaths() {
        let paths = CopiedPaths()
        #expect(paths.access(for: URL(filePath: "/net/example.invalid/a.txt")) == .remote)
        #expect(paths.access(for: URL(filePath: "/Network/Servers/example.invalid/a.txt")) == .remote)
    }
}
