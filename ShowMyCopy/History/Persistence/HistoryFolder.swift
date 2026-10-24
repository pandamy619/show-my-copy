import Foundation
import os

/// Where the saved history lives: `Application Support/ShowMyCopy/History` in the app's sandbox container, with the
/// database (`History.store`) and the image data (`Blobs`) inside.
enum HistoryFolder {
    static let appFolderName = "ShowMyCopy"
    static let folderName = "History"

    /// `Application Support/ShowMyCopy`, the app's own folder.
    static func appFolder(inApplicationSupport applicationSupport: URL) -> URL {
        applicationSupport.appending(path: appFolderName, directoryHint: .isDirectory)
    }

    /// `Application Support/ShowMyCopy/History`.
    static func directory(inApplicationSupport applicationSupport: URL) -> URL {
        appFolder(inApplicationSupport: applicationSupport).appending(path: folderName, directoryHint: .isDirectory)
    }

    /// The user's (sandboxed) Application Support folder, or nil when it cannot be found. Logs why.
    static func applicationSupport() -> URL? {
        do {
            return try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        } catch {
            AppLogger.history.error("Could not find Application Support")
            return nil
        }
    }
}

/// The history that development builds saved before the saved format was reset: `History.store` with its SQLite
/// side files, a `History.store.damaged` copy and the `Blobs` folder, directly in `Application Support/ShowMyCopy`.
/// The current history lives in `HistoryFolder`, so these files are told apart by where they are, without opening
/// them.
///
/// Delete them at launch before the history and its images are opened. They are never read: their format is
/// gone, and a partial read could only bring back part of a history.
struct LegacyHistoryFiles {
    enum Outcome: Equatable, Sendable {
        /// No such file: a new install, or they were deleted at an earlier launch.
        case nothingFound
        case deleted
        /// Some could not be deleted. The next launch tries again.
        case failed
    }

    static let storeFileName = "History.store"
    static let damagedStoreFileName = "History.store.damaged"
    static let blobsFolderName = "Blobs"

    /// `Application Support/ShowMyCopy`.
    let appFolder: URL

    /// The files and folders to delete, whether they exist or not.
    var urls: [URL] {
        let stores = [Self.storeFileName, Self.damagedStoreFileName].flatMap { name in
            StoreFiles.urls(forStoreAt: appFolder.appending(path: name, directoryHint: .notDirectory))
        }
        return stores + [appFolder.appending(path: Self.blobsFolderName, directoryHint: .isDirectory)]
    }

    /// Deletes every file and folder of the old history that exists. Each is deleted on its own, so one that
    /// cannot be deleted does not keep the others.
    @discardableResult
    func delete() -> Outcome {
        let fileManager = FileManager.default
        var found = 0
        var failed = 0
        for url in urls where fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            found += 1
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failed += 1
            }
        }
        guard found > 0 else {
            return .nothingFound
        }
        guard failed == 0 else {
            AppLogger.history.error("Could not delete all of the history saved by a development build")
            return .failed
        }
        AppLogger.history.info("Deleted the history saved by a development build in an older format")
        return .deleted
    }
}
