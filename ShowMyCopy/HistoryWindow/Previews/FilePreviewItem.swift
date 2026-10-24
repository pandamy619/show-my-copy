import Foundation
import Synchronization

/// One copied file in the preview of a file entry.
struct FilePreviewItem: Identifiable, Equatable, Sendable {
    /// The position in the entry.
    let id: Int
    /// The file name, sanitized like any other text in the history window.
    let name: String
    /// The path, for the file's icon. Not shown.
    let path: String
    /// The size when the file was copied, or nil for a folder or a file the app could not read.
    let byteSize: Int?
    /// The thumbnail of a photo or video, shown instead of the icon, or nil.
    let thumbnail: FileThumbnail?
    /// Nil while it is being checked.
    var availability: FileAvailability?

    init(id: Int, file: FileReference, availability: FileAvailability? = nil) {
        self.id = id
        name = EntryPreview.text(file.name)
        path = file.path
        byteSize = file.byteSize
        thumbnail = file.thumbnail
        self.availability = availability
    }
}

/// Checks copied files off the main actor: the checks touch the disk. Called for the entry that is shown (a row
/// that appears, the open preview), never for the whole history. All files of the entry together get `budget`, which
/// holds even when a check is stuck on a slow disk (`TimeLimit`); files not checked by then are `notChecked`.
enum FileAvailabilityProbe {
    static let budget: Duration = .seconds(2)

    @concurrent
    static func check(
        _ files: [FileReference],
        with checker: any FileAvailabilityChecking,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> [FileAvailability] {
        let checked = Mutex<[FileAvailability]>([])
        _ = await TimeLimit.run(within: budget, sleep: sleep) {
            for file in files {
                if Task.isCancelled {
                    return
                }
                let availability = checker.availability(of: file)
                checked.withLock { $0.append(availability) }
            }
        }
        let results = checked.withLock { $0 }
        return results + Array(repeating: .notChecked, count: max(files.count - results.count, 0))
    }

    /// One mark for a row: `mayBeUnavailable` when any of the files may be.
    static func summary(_ availabilities: [FileAvailability]) -> FileAvailability {
        availabilities.contains(.mayBeUnavailable) ? .mayBeUnavailable : .available
    }
}
