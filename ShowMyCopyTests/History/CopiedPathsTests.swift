import Foundation
import Testing

@testable import ShowMyCopy

/// Where copied paths are, judged from the path and the mount list before anything touches them.
struct CopiedPathsTests {
    private let volumes = [
        MountedVolume(mountPoint: "/", fileSystem: "apfs", isLocal: true),
        MountedVolume(mountPoint: "/System/Volumes/Data", fileSystem: "apfs", isLocal: true),
        MountedVolume(mountPoint: "/Volumes/USB", fileSystem: "msdos", isLocal: true),
        MountedVolume(mountPoint: "/Volumes/share", fileSystem: "smbfs", isLocal: false),
        MountedVolume(mountPoint: "/Volumes/nfs", fileSystem: "nfs", isLocal: false),
        MountedVolume(mountPoint: "/System/Volumes/Data/home", fileSystem: "autofs", isLocal: false),
        MountedVolume(mountPoint: "/Volumes/maps", fileSystem: "autofs", isLocal: true),
    ]

    private func access(_ path: String) -> PathAccess {
        CopiedPaths.access(forPath: path, volumes: volumes)
    }

    @Test func filesOnTheStartupDiskMayBeLookedAtAnywhere() {
        #expect(access("/Users/me/Documents/report.pdf") == .startupDisk)
        #expect(access("/System/Volumes/Data/Users/me/a.txt") == .startupDisk)
        #expect(access("/Applications/Notes.app") == .startupDisk)
    }

    @Test func filesOnOtherLocalDisksAreLookedAtOffTheMainActorOnly() {
        #expect(access("/Volumes/USB/photo.jpg") == .otherLocal)
    }

    @Test func filesInCloudFoldersAreLookedAtOffTheMainActorOnly() {
        #expect(access("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/a.txt") == .otherLocal)
        #expect(access("/Users/me/Library/CloudStorage/Dropbox/a.txt") == .otherLocal)
        #expect(access("/Users/me/Library/Preferences/a.plist") == .startupDisk)
    }

    @Test func filesOnNetworkVolumesAreNeverLookedAt() {
        #expect(access("/Volumes/share/a.txt") == .remote)
        #expect(access("/Volumes/nfs/deep/folder/a.txt") == .remote)
        #expect(access("/Volumes/share") == .remote)
    }

    @Test func automountedPathsAreNeverLookedAt() {
        // `/net` and `/Network` are autofs maps; looking a path up there makes automountd contact the host.
        #expect(access("/net/tracker.example/x") == .remote)
        #expect(access("/Network/Servers/host/a.txt") == .remote)
        #expect(access("/System/Volumes/Data/home/me/a.txt") == .remote)
        #expect(access("/Volumes/maps/a.txt") == .remote)
    }

    @Test func mountPointsMatchWholeComponents() {
        #expect(access("/Volumes/USB2/a.txt") == .startupDisk)
        #expect(access("/Volumes/shared/a.txt") == .startupDisk)
    }

    @Test func dotsAreResolvedByName() {
        #expect(access("/Volumes/USB/../share/a.txt") == .remote)
        #expect(access("/Users/me/./../../net/host/a") == .remote)
        #expect(access("/Volumes/share/../USB/a.txt") == .otherLocal)
    }

    @Test func pathsTheAppCannotPlaceAreNeverLookedAt() {
        #expect(access("relative/a.txt") == .remote)
        #expect(access("") == .remote)
        #expect(CopiedPaths.access(forPath: "/Users/me/a.txt", volumes: []) == .remote)
    }

    @Test func withoutAMountListNothingIsLookedAt() {
        let paths = CopiedPaths(volumes: FakeVolumes(nil))
        #expect(paths.access(for: URL(filePath: "/Users/me/a.txt")) == .remote)
    }

    @Test func urlsThatAreNotFileURLsAreNeverLookedAt() throws {
        let paths = CopiedPaths(volumes: FakeVolumes.startupDiskOnly)
        #expect(paths.access(for: try #require(URL(string: "https://example.com/a.txt"))) == .remote)
        #expect(paths.access(for: URL(filePath: "/Users/me/a.txt")) == .startupDisk)
    }
}
