import Foundation
import os

/// Keeps each blob in its own file, named by its ID, in one folder: `Application Support/ShowMyCopy/History/Blobs`
/// in the app's sandbox container, next to the history database.
///
/// The folder is excluded from backups like the database: images can hold anything that was copied, and a backup
/// would keep them after the entry is deleted. Files are written atomically, so a crash leaves either the whole
/// blob or none; a blob whose entry was never saved is deleted by the sweep at the next launch.
struct FileBlobStore: BlobStore {
    static let folderName = "Blobs"

    let directory: URL

    /// Opens the folder, creating it when needed, and excludes it from backups.
    init(directory: URL) throws(BlobStoreError) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            AppLogger.history.error(
                "Could not create the folder for images: \(String(describing: error), privacy: .private)")
            throw .openFailed
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = directory
        do {
            try excluded.setResourceValues(values)
        } catch {
            // Not a reason to stop saving: the folder is inside the sandbox container, whose Application Support
            // folder for the app is excluded too.
            AppLogger.history.error(
                "Could not exclude images from backups: \(String(describing: error), privacy: .private)")
        }
        self.directory = directory
    }

    /// `Application Support/ShowMyCopy/History/Blobs` in the user's (sandboxed) Application Support folder.
    static func openDefault() throws(BlobStoreError) -> FileBlobStore {
        guard let applicationSupport = HistoryFolder.applicationSupport() else {
            throw .openFailed
        }
        return try FileBlobStore(directory: directory(inApplicationSupport: applicationSupport))
    }

    static func directory(inApplicationSupport applicationSupport: URL) -> URL {
        HistoryFolder.directory(inApplicationSupport: applicationSupport)
            .appending(path: folderName, directoryHint: .isDirectory)
    }

    func write(_ data: Data) throws(BlobStoreError) -> BlobID {
        let id = BlobID()
        do {
            try data.write(to: url(for: id), options: .atomic)
        } catch {
            AppLogger.history.error("Could not save an image: \(String(describing: error), privacy: .private)")
            throw .writeFailed
        }
        return id
    }

    func read(_ id: BlobID) throws(BlobStoreError) -> Data {
        let url = url(for: id)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw .notFound
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer {
                do {
                    try handle.close()
                } catch {
                    AppLogger.history.error("Could not close a saved image")
                }
            }
            return try handle.readToEnd() ?? Data()
        } catch {
            AppLogger.history.error("Could not read a saved image: \(String(describing: error), privacy: .private)")
            throw .readFailed
        }
    }

    func delete(_ ids: [BlobID]) throws(BlobStoreError) {
        let fileManager = FileManager.default
        var failed = 0
        for id in ids {
            let url = url(for: id)
            guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else {
                continue
            }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            AppLogger.history.error("Could not delete \(failed, privacy: .public) saved images")
            throw .deleteFailed
        }
    }

    func size(of id: BlobID) -> Int? {
        fileSize(at: url(for: id))
    }

    func totalBytes() -> Int64 {
        let ids: Set<BlobID>
        do {
            ids = try allIDs()
        } catch {
            return 0
        }
        return ids.reduce(0) { $0 + Int64(size(of: $1) ?? 0) }
    }

    /// Only files named by a blob ID count; anything else in the folder, such as `.DS_Store`, is left alone.
    func allIDs() throws(BlobStoreError) -> Set<BlobID> {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        } catch {
            AppLogger.history.error("Could not list saved images: \(String(describing: error), privacy: .private)")
            throw .listFailed
        }
        return Set(names.compactMap { UUID(uuidString: $0).map { BlobID(uuid: $0) } })
    }

    private func url(for id: BlobID) -> URL {
        directory.appending(path: id.uuid.uuidString, directoryHint: .notDirectory)
    }

    private func fileSize(at url: URL) -> Int? {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return (attributes[.size] as? NSNumber)?.intValue
        } catch {
            AppLogger.history.error("Could not read the size of a saved image")
            return nil
        }
    }
}
