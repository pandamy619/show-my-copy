import Foundation
import Testing

@testable import ShowMyCopy

/// A new folder in the temporary directory, removed after `body`. It is not created: the store creates it.
func withTemporaryBlobDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "ShowMyCopyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "Blobs", directoryHint: .isDirectory)
    defer {
        let parent = directory.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path(percentEncoded: false)) {
            do {
                try FileManager.default.removeItem(at: parent)
            } catch {
                Issue.record("Could not remove the temporary directory: \(error)")
            }
        }
    }
    try body(directory)
}

/// The behaviour both blob stores share.
private func checkRoundTrip(_ store: any BlobStore) throws {
    let first = try store.write(Data([1, 2, 3]))
    let second = try store.write(Data(count: 1000))
    #expect(first != second)
    #expect(try store.read(first) == Data([1, 2, 3]))
    #expect(try store.read(second) == Data(count: 1000))
    #expect(store.size(of: first) == 3)
    #expect(store.size(of: second) == 1000)
    #expect(try store.allIDs() == [first, second])
    #expect(store.totalBytes() == 1003)

    try store.delete([first])
    #expect(store.size(of: first) == nil)
    #expect(throws: BlobStoreError.notFound) {
        try store.read(first)
    }
    #expect(try store.allIDs() == [second])
    #expect(store.totalBytes() == 1000)
}

private func checkDeletingMissingBlobs(_ store: any BlobStore) throws {
    let kept = try store.write(Data([7]))
    try store.delete([BlobID(), kept, BlobID()])
    #expect(try store.allIDs().isEmpty)
    try store.delete([])
}

struct InMemoryBlobStoreTests {
    @Test func writesReadsAndDeletes() throws {
        try checkRoundTrip(InMemoryBlobStore())
    }

    @Test func deletingMissingBlobsIsNotAnError() throws {
        try checkDeletingMissingBlobs(InMemoryBlobStore())
    }

    @Test func emptyDataIsABlobToo() throws {
        let store = InMemoryBlobStore()
        let id = store.write(Data())
        #expect(store.size(of: id) == 0)
        #expect(try store.read(id).isEmpty)
    }
}

struct FileBlobStoreTests {
    @Test func writesReadsAndDeletes() throws {
        try withTemporaryBlobDirectory { directory in
            try checkRoundTrip(try FileBlobStore(directory: directory))
        }
    }

    @Test func deletingMissingBlobsIsNotAnError() throws {
        try withTemporaryBlobDirectory { directory in
            try checkDeletingMissingBlobs(try FileBlobStore(directory: directory))
        }
    }

    @Test func createsItsFolder() throws {
        try withTemporaryBlobDirectory { directory in
            _ = try FileBlobStore(directory: directory)
            var isDirectory: ObjCBool = false
            let path = directory.path(percentEncoded: false)
            #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }

    @Test func keepsEachBlobInAFileNamedByItsID() throws {
        try withTemporaryBlobDirectory { directory in
            let store = try FileBlobStore(directory: directory)
            let id = try store.write(Data([9, 9]))
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            #expect(names == [id.uuid.uuidString])
        }
    }

    @Test func blobsOutliveTheStoreObject() throws {
        try withTemporaryBlobDirectory { directory in
            let id = try FileBlobStore(directory: directory).write(Data([4, 2]))
            let reopened = try FileBlobStore(directory: directory)
            #expect(try reopened.read(id) == Data([4, 2]))
        }
    }

    @Test func filesThatAreNotBlobsAreIgnored() throws {
        try withTemporaryBlobDirectory { directory in
            let store = try FileBlobStore(directory: directory)
            let id = try store.write(Data([1]))
            try Data(count: 50).write(to: directory.appending(path: ".DS_Store"))
            #expect(try store.allIDs() == [id])
            #expect(store.totalBytes() == 1)
        }
    }

    @Test func folderThatCannotBeCreatedFailsToOpen() throws {
        try withTemporaryBlobDirectory { directory in
            // A file where the folder should be.
            try FileManager.default.createDirectory(
                at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: directory)
            #expect(throws: BlobStoreError.openFailed) {
                try FileBlobStore(directory: directory)
            }
        }
    }

    @Test func defaultFolderIsBlobsNextToTheHistory() {
        let base = URL(filePath: "/tmp/Application Support", directoryHint: .isDirectory)
        #expect(
            FileBlobStore.directory(inApplicationSupport: base).path(percentEncoded: false)
                == "/tmp/Application Support/ShowMyCopy/History/Blobs/")
        let expected = HistoryFolder.directory(inApplicationSupport: base)
            .appending(path: "Blobs", directoryHint: .isDirectory)
        #expect(FileBlobStore.directory(inApplicationSupport: base) == expected)
    }
}
