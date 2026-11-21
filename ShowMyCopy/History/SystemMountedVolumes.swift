import Darwin
import Foundation

/// Lists mounted volumes with `getfsstat(MNT_NOWAIT)`: the kernel answers from what it already knows and does not ask
/// any file system, so a network volume that stopped responding does not make it wait. No path is touched.
struct SystemMountedVolumes: MountedVolumesReading {
    func mountedVolumes() -> [MountedVolume]? {
        // Volumes can be mounted between the two calls: ask for room for a few more.
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else {
            return nil
        }
        // `statfs` is also a function: in an expression `[statfs]` reads as an array of that function, so the
        // element type is given in a type position.
        var buffer: [statfs] = Array(repeating: statfs(), count: Int(count) + 8)
        let byteCount = Int32(clamping: buffer.count * MemoryLayout<statfs>.stride)
        let found = buffer.withUnsafeMutableBufferPointer { getfsstat($0.baseAddress, byteCount, MNT_NOWAIT) }
        guard found > 0 else {
            return nil
        }
        var volumes: [MountedVolume] = []
        for var info in buffer.prefix(Int(found)) {
            // A mount point that is not UTF-8 cannot be matched against paths, and a path on that volume would then
            // be taken for one on the volume above it, the startup disk included. Treat every path as remote instead.
            guard let mountPoint = Self.string(&info.f_mntonname), let fileSystem = Self.string(&info.f_fstypename)
            else {
                return nil
            }
            volumes.append(
                MountedVolume(
                    mountPoint: mountPoint, fileSystem: fileSystem, isLocal: info.f_flags & UInt32(MNT_LOCAL) != 0))
        }
        return volumes
    }

    /// A C string kept in a fixed-size array of `statfs`, up to its terminating zero, or nil when it is not UTF-8.
    private static func string<Characters>(_ characters: inout Characters) -> String? {
        withUnsafeBytes(of: &characters) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
        }
    }
}
