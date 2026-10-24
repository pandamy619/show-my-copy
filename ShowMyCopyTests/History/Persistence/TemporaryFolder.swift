import Foundation
import Testing

/// A new, empty folder in the temporary directory for tests that use real files, removed afterwards.
enum TemporaryFolder {
    static func with(_ body: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appending(path: "ShowMyCopyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            do {
                try fileManager.removeItem(at: folder)
            } catch {
                Issue.record("Could not remove the temporary folder: \(error)")
            }
        }
        try body(folder)
    }

    /// Writes `data` to `name` in `folder`, creating the folder when needed.
    static func write(_ data: Data = Data("saved".utf8), to name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: name, directoryHint: .notDirectory))
    }

    static func exists(_ name: String, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: name).path(percentEncoded: false))
    }

    /// A fresh UserDefaults suite, removed after `body`.
    static func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "ShowMyCopyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
