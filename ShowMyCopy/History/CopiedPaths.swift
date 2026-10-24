import Foundation

/// A mounted file system, as the kernel lists it.
struct MountedVolume: Equatable, Sendable {
    /// Where it is mounted, such as "/" or "/Volumes/Backup".
    let mountPoint: String
    /// The file system type, such as "apfs", "smbfs" or "autofs".
    let fileSystem: String
    /// Whether the kernel counts it as local (`MNT_LOCAL`): not a network file system.
    let isLocal: Bool
}

/// Lists the mounted volumes. The app's reader asks the kernel for what it already knows, without waiting for any
/// volume (`getfsstat` with `MNT_NOWAIT`), so it is quick and safe to call on the main actor.
protocol MountedVolumesReading: Sendable {
    /// The mounted volumes, or nil when they cannot be listed.
    func mountedVolumes() -> [MountedVolume]?
}

/// How the app may look at a copied path: its size, whether it is still there, its icon, its thumbnail.
enum PathAccess: Equatable, Sendable {
    /// On the startup disk, outside the folders of cloud file providers: its metadata comes at once, so it may be
    /// read on the main actor, as the icon of a history row is.
    case startupDisk
    /// On another local disk (external, removable, a disk image) or in an iCloud or other cloud folder, whose files
    /// may be placeholders: read off the main actor only, within a time limit, since a disk may have to spin up.
    case otherLocal
    /// On a network volume, under an automounted path (`/net`, `/Network`, autofs) or on a volume the app cannot
    /// place: never touched, since even looking a path up there can contact a server or wait for one.
    case remote
}

/// Decides where copied paths are, from the path and the mounted volumes alone, before anything touches the path.
struct CopiedPaths: Sendable {
    let volumes: any MountedVolumesReading

    init(volumes: any MountedVolumesReading = SystemMountedVolumes()) {
        self.volumes = volumes
    }

    func access(for url: URL) -> PathAccess {
        guard url.isFileURL, let volumes = volumes.mountedVolumes() else {
            return .remote
        }
        return Self.access(forPath: url.path(percentEncoded: false), volumes: volumes)
    }

    /// Autofs maps that macOS sets up by default: looking a path up under them makes `automountd` mount it, which
    /// for `/net/<host>` means contacting that host.
    static let automountedFolders: Set<String> = ["net", "Network"]

    /// The volumes of the startup disk: the system volume and, since macOS 10.15, the data volume beside it.
    static let startupMountPoints: Set<String> = ["/", "/System/Volumes/Data"]

    /// Folders in a user's Library where cloud file providers keep files that may be placeholders.
    static let cloudFolders: Set<String> = ["Mobile Documents", "CloudStorage"]

    /// The access for an absolute `path`, judged by the volume whose mount point is its longest prefix, component by
    /// component. A path that is not absolute, or is on no listed volume, is `remote`.
    static func access(forPath path: String, volumes: [MountedVolume]) -> PathAccess {
        guard let components = normalizedComponents(of: path) else {
            return .remote
        }
        if let first = components.first, automountedFolders.contains(first) {
            return .remote
        }
        let volume =
            volumes
            .compactMap { volume in
                normalizedComponents(of: volume.mountPoint).map { (volume: volume, components: $0) }
            }
            .filter { components.starts(with: $0.components) }
            .max { $0.components.count < $1.components.count }
        guard let volume, volume.volume.isLocal, volume.volume.fileSystem != "autofs" else {
            return .remote
        }
        guard startupMountPoints.contains(volume.volume.mountPoint), !isInCloudFolder(components) else {
            return .otherLocal
        }
        return .startupDisk
    }

    /// The path's components with "." and ".." resolved by name, or nil for a path that is not absolute. Symbolic
    /// links are not followed: that would touch the path.
    static func normalizedComponents(of path: String) -> [String]? {
        guard path.hasPrefix("/") else {
            return nil
        }
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                _ = components.popLast()
            default:
                components.append(String(component))
            }
        }
        return components
    }

    private static func isInCloudFolder(_ components: [String]) -> Bool {
        zip(components, components.dropFirst()).contains { $0 == "Library" && cloudFolders.contains($1) }
    }
}
