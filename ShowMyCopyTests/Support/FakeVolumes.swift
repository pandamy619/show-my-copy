import Foundation

@testable import ShowMyCopy

/// A fixed mount list, or none at all.
struct FakeVolumes: MountedVolumesReading {
    let volumes: [MountedVolume]?

    init(_ volumes: [MountedVolume]?) {
        self.volumes = volumes
    }

    /// A Mac whose files are all on the startup disk.
    static let startupDiskOnly = FakeVolumes([MountedVolume(mountPoint: "/", fileSystem: "apfs", isLocal: true)])

    func mountedVolumes() -> [MountedVolume]? {
        volumes
    }
}
