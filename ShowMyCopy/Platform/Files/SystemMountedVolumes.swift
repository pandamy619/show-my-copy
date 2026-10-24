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
        var buffer = [statfs](repeating: statfs(), count: Int(count) + 8)
        let byteCount = Int32(clamping: buffer.count * MemoryLayout<statfs>.stride)
        let found = buffer.withUnsafeMutableBufferPointer { getfsstat($0.baseAddress, byteCount, MNT_NOWAIT) }
        guard found > 0 else {
            return nil
        }
        return buffer.prefix(Int(found)).map { info in
            var info = info
            return MountedVolume(
                mountPoint: Self.string(&info.f_mntonname),
                fileSystem: Self.string(&info.f_fstypename),
                isLocal: info.f_flags & UInt32(MNT_LOCAL) != 0
            )
        }
    }

    /// A C string kept in a fixed-size array of `statfs`, up to its terminating zero. Empty when it is not UTF-8,
    /// which matches no path, so such a volume is never taken for the startup disk.
    private static func string<Characters>(_ characters: inout Characters) -> String {
        withUnsafeBytes(of: &characters) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
    }
}
