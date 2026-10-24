import Foundation
import Testing

@testable import ShowMyCopy

/// Builds QuickTime and MPEG-4 box structures for tests.
enum MovieBoxes {
    /// A box with an 8-byte header.
    static func box(_ type: String, _ payload: Data = Data()) -> Data {
        var data = bigEndian(UInt32(8 + payload.count))
        data.append(contentsOf: Array(type.utf8))
        data.append(payload)
        return data
    }

    /// A box with a 16-byte header (size 1, then a 64-bit size).
    static func largeBox(_ type: String, _ payload: Data) -> Data {
        var data = bigEndian(UInt32(1))
        data.append(contentsOf: Array(type.utf8))
        data.append(bigEndian64(UInt64(16 + payload.count)))
        data.append(payload)
        return data
    }

    static let fileType = box("ftyp", Data(Array("qt  ".utf8) + [0, 0, 2, 0] + Array("qt  ".utf8)))
    static let header = box("mvhd", Data(count: 100))
    static let track = box("trak", box("tkhd", Data(count: 84)))
    static let media = box("mdat", Data(repeating: 7, count: 64))

    /// A movie that holds its own media: `ftyp`, `mdat`, then `moov`, as `AVAssetWriter` writes it.
    static let selfContained = fileType + media + box("moov", header + track)

    /// A reference movie: `moov` holds a reference movie record pointing at a URL, and there is no media.
    static let reference =
        fileType
        + box("moov", box("rmra", box("rmda", box("rdrf", Data(Array("url ".utf8) + Array("https://e.x/m".utf8))))))

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
    }

    private static func bigEndian64(_ value: UInt64) -> Data {
        Data([56, 48, 40, 32, 24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
    }
}

/// Reads ranges of in-memory file data and counts the bytes asked for.
final class MovieDataReader {
    let data: Data
    private(set) var bytesRead = 0

    init(_ data: Data) {
        self.data = data
    }

    var fileSize: UInt64 {
        UInt64(data.count)
    }

    func read(_ offset: UInt64, _ count: Int) -> Data? {
        guard offset <= UInt64(data.count) else {
            return nil
        }
        let start = Int(offset)
        let chunk = data[start..<min(data.count, start + count)]
        bytesRead += chunk.count
        return Data(chunk)
    }
}

struct FileThumbnailPolicyTests {
    @Test func onlyAllowedImagesAndThreeMovieTypesAreCandidates() {
        #expect(FileThumbnailPolicy.candidate(forContentType: "public.png") == .image(.png))
        #expect(FileThumbnailPolicy.candidate(forContentType: "public.jpeg") == .image(.jpeg))
        #expect(FileThumbnailPolicy.candidate(forContentType: "public.heic") == .image(.heic))
        #expect(FileThumbnailPolicy.candidate(forContentType: "public.heif") == .image(.heic))
        #expect(FileThumbnailPolicy.candidate(forContentType: "public.tiff") == .image(.tiff))
        #expect(FileThumbnailPolicy.candidate(forContentType: "com.compuserve.gif") == .image(.gif))
        #expect(FileThumbnailPolicy.candidate(forContentType: "org.webmproject.webp") == .image(.webp))
        #expect(FileThumbnailPolicy.candidate(forContentType: "com.microsoft.bmp") == .image(.bmp))
        #expect(FileThumbnailPolicy.candidate(forContentType: "com.apple.quicktime-movie") == .movie)
        #expect(FileThumbnailPolicy.candidate(forContentType: "public.mpeg-4") == .movie)
        #expect(FileThumbnailPolicy.candidate(forContentType: "com.apple.m4v-video") == .movie)
    }

    @Test func typesThatCanLoadOtherResourcesAreNotCandidates() {
        let excluded = [
            "public.svg-image", "com.adobe.pdf", "com.apple.quicktime-link", "public.m3u-playlist",
            "com.apple.mpegurl-playlist", "public.html", "com.adobe.raw-image", "com.adobe.photoshop-image",
            "public.avif", "com.apple.icns", "public.image", "public.movie", "public.avi", "org.matroska.mkv",
            "com.microsoft.windows-media-wmv", "public.3gpp", "",
        ]
        for type in excluded {
            #expect(FileThumbnailPolicy.candidate(forContentType: type) == nil, "\(type)")
        }
    }
}

struct MovieContainerTests {
    private func holdsItsOwnMedia(_ data: Data) -> Bool {
        let reader = MovieDataReader(data)
        return MovieContainer.holdsItsOwnMedia(fileSize: reader.fileSize, read: reader.read)
    }

    @Test func movieWithItsOwnMediaPasses() {
        #expect(holdsItsOwnMedia(MovieBoxes.selfContained))
        // `moov` before `mdat` (fast start) and an MPEG-4 file type.
        let mp4Type = MovieBoxes.box("ftyp", Data(Array("isom".utf8) + [0, 0, 2, 0] + Array("isommp41".utf8)))
        #expect(
            holdsItsOwnMedia(mp4Type + MovieBoxes.box("moov", MovieBoxes.header) + MovieBoxes.media))
        // Old QuickTime files have no `ftyp` and may pad with `wide`.
        let old = MovieBoxes.box("wide") + MovieBoxes.media + MovieBoxes.box("moov", MovieBoxes.header)
        #expect(holdsItsOwnMedia(old))
    }

    @Test func largeBoxesAndABoxToTheEndOfTheFileAreRead() {
        let large =
            MovieBoxes.fileType + MovieBoxes.largeBox("mdat", Data(count: 32))
            + MovieBoxes.box("moov", MovieBoxes.header)
        #expect(holdsItsOwnMedia(large))
        // Size 0: the last box runs to the end of the file.
        var toTheEnd = MovieBoxes.fileType + MovieBoxes.box("moov", MovieBoxes.header)
        toTheEnd.append(contentsOf: [0, 0, 0, 0] + Array("mdat".utf8) + Array(repeating: 1, count: 40))
        #expect(holdsItsOwnMedia(toTheEnd))
    }

    @Test func referenceMoviesAndMoviesWithoutMediaAreRejected() {
        #expect(!holdsItsOwnMedia(MovieBoxes.reference))
        // A reference record next to media of its own is still a reference movie.
        #expect(
            !holdsItsOwnMedia(
                MovieBoxes.fileType + MovieBoxes.media
                    + MovieBoxes.box("moov", MovieBoxes.header + MovieBoxes.box("rmra"))))
        // No media data, or an empty `mdat`.
        #expect(!holdsItsOwnMedia(MovieBoxes.fileType + MovieBoxes.box("moov", MovieBoxes.header)))
        #expect(
            !holdsItsOwnMedia(
                MovieBoxes.fileType + MovieBoxes.box("mdat") + MovieBoxes.box("moov", MovieBoxes.header)))
        // No `moov`.
        #expect(!holdsItsOwnMedia(MovieBoxes.fileType + MovieBoxes.media))
    }

    @Test func malformedFilesAreRejected() {
        #expect(!holdsItsOwnMedia(Data()))
        #expect(!holdsItsOwnMedia(Data("not a movie at all".utf8)))
        // A box that claims to be larger than the file.
        var tooLong = MovieBoxes.selfContained
        tooLong.replaceSubrange(0..<4, with: [0, 0, 0x10, 0])
        #expect(!holdsItsOwnMedia(tooLong))
        // A box smaller than its header, which would never move on.
        #expect(!holdsItsOwnMedia(Data([0, 0, 0, 4] + Array("ftyp".utf8)) + MovieBoxes.media))
        // A cut-off header at the end.
        #expect(!holdsItsOwnMedia(MovieBoxes.selfContained + Data([0, 0, 0])))
        // A large box whose 64-bit size is cut off.
        #expect(!holdsItsOwnMedia(MovieBoxes.selfContained + Data([0, 0, 0, 1] + Array("mdat".utf8) + [0, 0])))
    }

    @Test func readsOnlyBoxHeadersAndAtMostSoManyBoxes() {
        let media = MovieBoxes.box("mdat", Data(repeating: 7, count: 100_000))
        let reader = MovieDataReader(MovieBoxes.fileType + media + MovieBoxes.box("moov", MovieBoxes.header))
        #expect(MovieContainer.holdsItsOwnMedia(fileSize: reader.fileSize, read: reader.read))
        // Three top-level headers and one inside `moov`, 16 bytes each at most.
        #expect(reader.bytesRead <= 4 * 16)

        let many = (0...MovieContainer.maximumBoxes).reduce(Data()) { data, _ in data + MovieBoxes.box("free") }
        #expect(!holdsItsOwnMedia(many + MovieBoxes.media + MovieBoxes.box("moov", MovieBoxes.header)))
        let enough = (1..<(MovieContainer.maximumBoxes - 2)).reduce(Data()) { data, _ in data + MovieBoxes.box("free") }
        #expect(holdsItsOwnMedia(enough + MovieBoxes.media + MovieBoxes.box("moov", MovieBoxes.header)))
    }

    @Test func aFileThatCannotBeReadIsRejected() {
        #expect(!MovieContainer.holdsItsOwnMedia(fileSize: 1000) { _, _ in nil })
    }
}
