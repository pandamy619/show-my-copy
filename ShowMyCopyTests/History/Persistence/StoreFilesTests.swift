import Foundation
import Testing

@testable import ShowMyCopy

struct StoreFilesTests {
    /// A new folder in the temporary directory, removed after `body`.
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ShowMyCopyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Could not remove the temporary directory: \(error)")
            }
        }
        try body(directory)
    }

    @Test func storeComesWithItsSQLiteSideFiles() {
        let store = URL(filePath: "/tmp/ShowMyCopy/History.store")
        #expect(
            StoreFiles.urls(forStoreAt: store).map(\.lastPathComponent)
                == ["History.store", "History.store-wal", "History.store-shm"])
    }

    @Test func sumsTheFilesThatExist() throws {
        try withTemporaryDirectory { directory in
            let store = directory.appending(path: "History.store")
            try Data(count: 4096).write(to: store)
            try Data(count: 1000).write(to: directory.appending(path: "History.store-wal"))
            // No -shm file: SQLite removes it when the store is closed.
            try Data(count: 7).write(to: directory.appending(path: "Other.store"))

            #expect(StoreFiles.totalBytes(ofStoreAt: store) == 5096)
        }
    }

    @Test func noFilesIsUnknown() throws {
        try withTemporaryDirectory { directory in
            #expect(StoreFiles.totalBytes(ofStoreAt: directory.appending(path: "History.store")) == nil)
        }
    }
}
