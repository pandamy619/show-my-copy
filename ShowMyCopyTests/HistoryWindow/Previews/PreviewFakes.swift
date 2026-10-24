import Foundation
import Synchronization

@testable import ShowMyCopy

/// A decoded image that remembers which data it came from.
struct FakePreviewImage: PreviewImage, Equatable {
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Decodes any data except `FakeImageDecoder.notAnImage` into a `FakePreviewImage` of `size` pixels, scaled down to
/// the requested maximum. Counts its calls and remembers the sizes asked for.
final class FakeImageDecoder: PreviewImageDecoding {
    static let notAnImage = Data("not an image".utf8)

    private let size: (width: Int, height: Int)
    private let calls = Mutex<[Int]>([])

    init(width: Int = 256, height: Int = 192) {
        size = (width, height)
    }

    var decodeCount: Int {
        calls.withLock { $0.count }
    }

    var requestedPixelSizes: [Int] {
        calls.withLock { $0 }
    }

    func decode(_ data: Data, maximumPixelSize: Int) -> (any PreviewImage)? {
        calls.withLock { $0.append(maximumPixelSize) }
        guard data != Self.notAnImage else {
            return nil
        }
        let scale = min(1, Double(maximumPixelSize) / Double(max(size.width, size.height)))
        return FakePreviewImage(
            data: data, pixelWidth: Int(Double(size.width) * scale), pixelHeight: Int(Double(size.height) * scale))
    }
}

/// Wraps a blob store and counts the blobs read, by ID.
final class ReadCountingBlobStore: BlobStore {
    let base = InMemoryBlobStore()
    private let reads = Mutex<[BlobID]>([])

    func readCount(of id: BlobID) -> Int {
        reads.withLock { $0.filter { $0 == id }.count }
    }

    var totalReads: Int {
        reads.withLock { $0.count }
    }

    func write(_ data: Data) throws(BlobStoreError) -> BlobID {
        base.write(data)
    }

    func read(_ id: BlobID) throws(BlobStoreError) -> Data {
        reads.withLock { $0.append(id) }
        return try base.read(id)
    }

    func delete(_ ids: [BlobID]) throws(BlobStoreError) {
        base.delete(ids)
    }

    func size(of id: BlobID) -> Int? {
        base.size(of: id)
    }

    func totalBytes() -> Int64 {
        base.totalBytes()
    }

    func allIDs() throws(BlobStoreError) -> Set<BlobID> {
        base.allIDs()
    }
}

struct FakeRenderedRichText: RenderedRichText, Equatable {
    let rtf: Data
}

/// Renders any RTF except `FakeRichTextRenderer.unreadable`.
struct FakeRichTextRenderer: RichTextRendering {
    static let unreadable = Data("{\\rtf1 broken".utf8)

    func render(rtf: Data) -> (any RenderedRichText)? {
        rtf == Self.unreadable ? nil : FakeRenderedRichText(rtf: rtf)
    }
}

/// Says that the files under `missing` may be unavailable, and every other file is available.
struct FakeAvailabilityChecker: FileAvailabilityChecking {
    var missing: Set<String> = []

    func availability(of file: FileReference) -> FileAvailability {
        missing.contains(file.path) ? .mayBeUnavailable : .available
    }
}
