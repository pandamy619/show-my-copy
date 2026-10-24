import Foundation
import Testing

@testable import ShowMyCopy

/// The history that development builds saved before the format was reset is deleted, never read.
struct LegacyHistoryFilesTests {
    private let fileManager = FileManager.default

    /// A new Application Support folder in the temporary directory, removed after `body`.
    private func withApplicationSupport(_ body: (URL) throws -> Void) throws {
        let directory = fileManager.temporaryDirectory
            .appending(path: "ShowMyCopyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                Issue.record("Could not remove the temporary directory: \(error)")
            }
        }
        try body(directory)
    }

    private func write(_ name: String, in folder: URL) throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("saved".utf8).write(to: folder.appending(path: name, directoryHint: .notDirectory))
    }

    private func exists(_ name: String, in folder: URL) -> Bool {
        fileManager.fileExists(atPath: folder.appending(path: name).path(percentEncoded: false))
    }

    /// Files as the builds before the reset left them in `Application Support/ShowMyCopy`.
    private func writeLegacyHistory(in appFolder: URL) throws {
        for name in [
            "History.store", "History.store-wal", "History.store-shm", "History.store.damaged",
            "History.store.damaged-wal", "History.store.damaged-shm",
        ] {
            try write(name, in: appFolder)
        }
        let blobs = appFolder.appending(path: "Blobs", directoryHint: .isDirectory)
        try write(UUID().uuidString, in: blobs)
        try write(UUID().uuidString, in: blobs)
    }

    @Test func historyLivesInItsOwnFolder() {
        let base = URL(filePath: "/tmp/Application Support", directoryHint: .isDirectory)
        #expect(
            HistoryFolder.directory(inApplicationSupport: base).path(percentEncoded: false)
                == "/tmp/Application Support/ShowMyCopy/History/")
        #expect(
            HistoryFolder.appFolder(inApplicationSupport: base).path(percentEncoded: false)
                == "/tmp/Application Support/ShowMyCopy/")
    }

    @Test func deletesTheOldStoreItsSideFilesDamagedCopiesAndImages() throws {
        try withApplicationSupport { support in
            let appFolder = HistoryFolder.appFolder(inApplicationSupport: support)
            try writeLegacyHistory(in: appFolder)

            #expect(LegacyHistoryFiles(appFolder: appFolder).delete() == .deleted)
            #expect(try fileManager.contentsOfDirectory(atPath: appFolder.path(percentEncoded: false)).isEmpty)
        }
    }

    @Test func leavesTheCurrentHistoryAndOtherFilesAlone() throws {
        try withApplicationSupport { support in
            let appFolder = HistoryFolder.appFolder(inApplicationSupport: support)
            let current = HistoryFolder.directory(inApplicationSupport: support)
            try writeLegacyHistory(in: appFolder)
            try write("History.store", in: current)
            try write("History.store.damaged", in: current)
            let blob = UUID().uuidString
            try write(blob, in: FileBlobStore.directory(inApplicationSupport: support))
            try write("Notes.txt", in: appFolder)

            #expect(LegacyHistoryFiles(appFolder: appFolder).delete() == .deleted)
            #expect(exists("History.store", in: current))
            #expect(exists("History.store.damaged", in: current))
            #expect(exists(blob, in: FileBlobStore.directory(inApplicationSupport: support)))
            #expect(exists("Notes.txt", in: appFolder))
            #expect(!exists("History.store", in: appFolder))
            #expect(!exists("Blobs", in: appFolder))
        }
    }

    @Test func findsNothingOnANewInstallOrTheNextLaunch() throws {
        try withApplicationSupport { support in
            let appFolder = HistoryFolder.appFolder(inApplicationSupport: support)
            #expect(LegacyHistoryFiles(appFolder: appFolder).delete() == .nothingFound)

            try writeLegacyHistory(in: appFolder)
            #expect(LegacyHistoryFiles(appFolder: appFolder).delete() == .deleted)
            #expect(LegacyHistoryFiles(appFolder: appFolder).delete() == .nothingFound)
        }
    }

    @Test func aStoreWithoutImagesOrAnImageFolderAloneIsDeletedToo() throws {
        try withApplicationSupport { support in
            let appFolder = HistoryFolder.appFolder(inApplicationSupport: support)
            try write("History.store", in: appFolder)
            #expect(LegacyHistoryFiles(appFolder: appFolder).delete() == .deleted)
            #expect(!exists("History.store", in: appFolder))

            try write(UUID().uuidString, in: appFolder.appending(path: "Blobs", directoryHint: .isDirectory))
            #expect(LegacyHistoryFiles(appFolder: appFolder).delete() == .deleted)
            #expect(!exists("Blobs", in: appFolder))
        }
    }
}
