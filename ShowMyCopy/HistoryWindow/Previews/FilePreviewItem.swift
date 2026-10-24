import Foundation

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
    /// Nil while it is being checked.
    var availability: FileAvailability?

    init(id: Int, file: FileReference, availability: FileAvailability? = nil) {
        self.id = id
        name = EntryPreview.text(file.name)
        path = file.path
        byteSize = file.byteSize
        self.availability = availability
    }
}

/// Checks copied files off the main actor: the checks touch the disk. Called for the entry that is shown (a row
/// that appears, the open preview), never for the whole history.
enum FileAvailabilityProbe {
    @concurrent
    static func check(
        _ files: [FileReference],
        with checker: any FileAvailabilityChecking
    ) async -> [FileAvailability] {
        var results: [FileAvailability] = []
        results.reserveCapacity(files.count)
        for file in files {
            if Task.isCancelled {
                break
            }
            results.append(checker.availability(of: file))
        }
        return results
    }

    /// One mark for a row: `mayBeUnavailable` when any of the files may be.
    static func summary(_ availabilities: [FileAvailability]) -> FileAvailability {
        availabilities.contains(.mayBeUnavailable) ? .mayBeUnavailable : .available
    }
}
