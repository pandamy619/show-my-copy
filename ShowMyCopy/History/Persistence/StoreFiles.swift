import Foundation
import os

/// The files of a SQLite store, such as the one SwiftData keeps the history in.
enum StoreFiles {
    /// SQLite keeps recent changes in these files next to the store until it checkpoints them.
    static let suffixes = ["", "-wal", "-shm"]

    /// The store file and its side files, whether they exist or not.
    static func urls(forStoreAt store: URL) -> [URL] {
        let directory = store.deletingLastPathComponent()
        return suffixes.map { directory.appending(path: store.lastPathComponent + $0, directoryHint: .notDirectory) }
    }

    /// The total size of the store's files that exist, or nil when none does or a size cannot be read.
    static func totalBytes(ofStoreAt store: URL) -> Int64? {
        let fileManager = FileManager.default
        var total: Int64 = 0
        var found = false
        for url in urls(forStoreAt: store) {
            let path = url.path(percentEncoded: false)
            guard fileManager.fileExists(atPath: path) else {
                continue
            }
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: path)
            } catch {
                AppLogger.history.error(
                    "Could not read the size of the history: \(String(describing: error), privacy: .private)")
                return nil
            }
            guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
                AppLogger.history.error("The size of the history file is missing")
                return nil
            }
            total += size
            found = true
        }
        return found ? total : nil
    }
}
