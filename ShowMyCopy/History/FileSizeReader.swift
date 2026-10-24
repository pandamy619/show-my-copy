import Foundation
import Synchronization

/// Reads the sizes of copied files after they are recorded, off the main actor.
///
/// Reading a size reads the file system's metadata, which can wait for a disk to spin up or a server to answer. So
/// copied files are recorded without sizes and this fills them in afterwards (`CaptureEnrichment`): only for files the
/// app may look at (`CopiedPaths`; nothing on a network volume or an automounted path), and all of one copy within
/// `budget`. A file whose size is not read by then, or cannot be read, shows none.
struct FileSizeReader: Sendable {
    /// How long the sizes of one copy may take. The thumbnails of the copy wait for them, so this stays short.
    static let budget: Duration = .seconds(1)

    let paths: CopiedPaths
    private let size: @Sendable (URL) async -> Int?
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        paths: CopiedPaths = CopiedPaths(),
        size: @escaping @Sendable (URL) async -> Int? = { FileSizeReader.sizeOfFile(at: $0) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.paths = paths
        self.size = size
        self.sleep = sleep
    }

    /// `files` in the same order, with the sizes read in time filled in. Sizes they had stay.
    @concurrent
    func sizes(of files: [FileReference]) async -> [FileReference] {
        let paths = paths
        let wanted = files.enumerated().filter {
            $0.element.byteSize == nil && paths.access(for: $0.element.url) != .remote
        }
        guard !wanted.isEmpty else {
            return files
        }
        let read = Mutex<[Int: Int]>([:])
        let size = size
        let finished: Void? = await TimeLimit.run(within: Self.budget, sleep: sleep) {
            for (index, file) in wanted {
                if Task.isCancelled {
                    return
                }
                if let bytes = await size(file.url) {
                    read.withLock { $0[index] = bytes }
                }
            }
        }
        if finished == nil {
            AppLogger.clipboard.info("Sizes of copied files took too long; the rest are not shown")
        }
        let sizes = read.withLock { $0 }
        return files.enumerated().map { index, file in
            sizes[index].map { file.withByteSize($0) } ?? file
        }
    }

    /// The size of a regular file, or nil for a folder, a missing file or one the sandbox does not let the app see.
    /// Not knowing the size is normal in the sandbox, so it is not logged. Reads the metadata of the item itself, not
    /// of what a symbolic link points to.
    static func sizeOfFile(at url: URL) -> Int? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        } catch {
            return nil
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.intValue
    }
}
