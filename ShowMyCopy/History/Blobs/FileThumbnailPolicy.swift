import Foundation

/// Which copied files QuickLook is asked to make a thumbnail of.
///
/// QuickLook draws thumbnails in system processes (or third-party Quick Look extensions) outside the app's sandbox,
/// with their own rights, which can include the network. So it is asked only about formats that are drawn from the
/// file alone: the images of `ImageFormat` and three movie types, matched exactly, not by conformance. Left out are,
/// among others, SVG (which can load external resources), PDF, QuickTime links and playlists, RAW photos and any type
/// only a third-party extension draws.
enum FileThumbnailPolicy {
    /// What QuickLook may be asked about.
    enum Candidate: Equatable, Sendable {
        /// An image file. Its bytes must be this format and its header within `ImageDecodingPolicy`.
        case image(ImageFormat)
        /// A movie file. It must hold its own media (`MovieContainer.holdsItsOwnMedia`).
        case movie
    }

    /// QuickTime (.mov), MPEG-4 (.mp4) and iTunes video (.m4v).
    static let movieTypes: Set<String> = ["com.apple.quicktime-movie", "public.mpeg-4", "com.apple.m4v-video"]

    /// The candidate for a file of this content type (its Uniform Type Identifier), or nil for any other type.
    static func candidate(forContentType identifier: String) -> Candidate? {
        if movieTypes.contains(identifier) {
            return .movie
        }
        return ImageFormat(typeIdentifier: identifier).map(Candidate.image)
    }
}

/// Reads the box structure of a QuickTime or MPEG-4 file, headers only, to tell a movie that holds its own media
/// from a reference movie, whose media is somewhere else, possibly at a URL.
///
/// Only box headers (8 or 16 bytes each) are read: the top level of the file and the boxes directly inside `moov`,
/// at most `maximumBoxes` of each. Nothing of the media is read or kept.
enum MovieContainer {
    /// The most boxes looked at on one level. Real files have a handful at the top level and in `moov`.
    static let maximumBoxes = 64

    struct Box: Equatable, Sendable {
        let type: String
        let offset: UInt64
        let headerLength: UInt64
        let size: UInt64

        var payload: Range<UInt64> {
            (offset + headerLength)..<(offset + size)
        }
    }

    /// Whether the file has a `moov` box without a reference movie record (`rmra`) and a non-empty `mdat` box, the
    /// media data, at its top level. False for a malformed file or one with too many boxes.
    ///
    /// This rules out reference movies and movies whose media is all elsewhere. A crafted movie can still name
    /// external data for one track next to media of its own; whether the system's movie thumbnailer follows that is
    /// up to macOS, which is why SECURITY.md says QuickLook runs outside the app's sandbox.
    ///
    /// `read(offset, count)` gives up to `count` bytes of the file from `offset`, or nil when it cannot.
    static func holdsItsOwnMedia(fileSize: UInt64, read: (UInt64, Int) -> Data?) -> Bool {
        guard let top = boxes(in: 0..<fileSize, read: read),
            let movie = top.first(where: { $0.type == "moov" }),
            top.contains(where: { $0.type == "mdat" && !$0.payload.isEmpty }),
            let inside = boxes(in: movie.payload, read: read)
        else {
            return false
        }
        return !inside.contains { $0.type == "rmra" }
    }

    /// The boxes that fill `range` exactly, or nil when a header is cut off or malformed, a box runs past the end
    /// of `range`, or there are more than `maximumBoxes`.
    static func boxes(in range: Range<UInt64>, read: (UInt64, Int) -> Data?) -> [Box]? {
        var result: [Box] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard result.count < maximumBoxes else {
                return nil
            }
            let remaining = range.upperBound - offset
            guard remaining >= 8, let data = read(offset, Int(min(remaining, 16))) else {
                return nil
            }
            let header = [UInt8](data)
            guard header.count >= 8 else {
                return nil
            }
            let declared = bigEndian(header[0..<4])
            let headerLength: UInt64
            let size: UInt64
            switch declared {
            case 0:
                // The box runs to the end of the file (or of its parent).
                headerLength = 8
                size = remaining
            case 1:
                guard header.count >= 16 else {
                    return nil
                }
                headerLength = 16
                size = bigEndian(header[8..<16])
            default:
                headerLength = 8
                size = declared
            }
            guard size >= headerLength, size <= remaining else {
                return nil
            }
            let type = String(decoding: header[4..<8], as: Unicode.ASCII.self)
            result.append(Box(type: type, offset: offset, headerLength: headerLength, size: size))
            offset += size
        }
        return result
    }

    private static func bigEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }
}
