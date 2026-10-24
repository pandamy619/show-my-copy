import Foundation

/// The binary layout of the payloads of every record.
///
/// Hand-written rather than JSON or a property list: the layout is fixed and cannot fail to encode, so writing a
/// record never throws for it, and reading checks every length against the data, so a damaged record is reported
/// as unreadable instead of crashing. Every payload starts with the same format byte, `format`; there is one
/// layout for each kind and no other version. Integers are big-endian; strings are UTF-8; variable-length parts
/// are length-prefixed, except text, which is the rest of the payload.
enum StoredPayload {
    /// The first byte of every payload. A payload that starts with another byte is unreadable.
    static let format: UInt8 = 1

    static func encode(_ content: ClipboardContent) -> Data {
        var writer = Writer()
        writer.byte(format)
        switch content {
        case .text(let text):
            writer.raw(Data(text.utf8))
        case .richText(let rtf, let plain):
            writer.bytes(rtf)
            writer.string(plain)
        case .image(let image):
            writer.uuid(image.blobID.uuid)
            writer.string(image.typeIdentifier)
            writer.integer(image.pixelWidth)
            writer.integer(image.pixelHeight)
            writer.integer(image.byteSize)
            writer.bytes(Data(image.contentHash.bytes))
            if let thumbnail = image.thumbnail {
                writer.byte(1)
                writer.uuid(thumbnail.blobID.uuid)
                writer.integer(thumbnail.pixelWidth)
                writer.integer(thumbnail.pixelHeight)
                writer.integer(thumbnail.byteSize)
            } else {
                writer.byte(0)
            }
        case .files(let files):
            writer.integer(files.count)
            for file in files {
                writer.string(file.url.absoluteString)
                writer.string(file.name)
                if let byteSize = file.byteSize {
                    writer.byte(1)
                    writer.integer(byteSize)
                } else {
                    writer.byte(0)
                }
                writer.fileThumbnail(file.thumbnail)
            }
        }
        return writer.data
    }

    /// The content of `kind` saved as `payload`, or nil when the data is damaged or in an unknown layout.
    static func decode(_ kind: ClipboardContent.Kind, from payload: Data) -> ClipboardContent? {
        var reader = Reader(payload)
        guard reader.byte() == format else {
            return nil
        }
        let content: ClipboardContent?
        switch kind {
        case .text:
            content = String(data: reader.rest(), encoding: .utf8).map { .text($0) }
        case .richText:
            content = decodeRichText(&reader)
        case .image:
            content = decodeImage(&reader).map { .image($0) }
        case .files:
            content = decodeFiles(&reader).map { .files($0) }
        }
        // Trailing bytes mean the layout is not the one written.
        guard reader.isAtEnd else {
            return nil
        }
        return content
    }

    private static func decodeRichText(_ reader: inout Reader) -> ClipboardContent? {
        guard let rtf = reader.bytes(), let plain = reader.string() else {
            return nil
        }
        return .richText(rtf: rtf, plain: plain)
    }

    private static func decodeImage(_ reader: inout Reader) -> ImageReference? {
        guard let blob = reader.uuid(), let type = reader.string(), !type.isEmpty,
            let width = reader.integer(), let height = reader.integer(), let byteSize = reader.integer(),
            let hash = reader.bytes(), !hash.isEmpty, let hasThumbnail = reader.byte()
        else {
            return nil
        }
        var thumbnail: ThumbnailReference?
        switch hasThumbnail {
        case 0:
            thumbnail = nil
        case 1:
            guard let thumbnailBlob = reader.uuid(), let thumbnailWidth = reader.integer(),
                let thumbnailHeight = reader.integer(), let thumbnailBytes = reader.integer()
            else {
                return nil
            }
            thumbnail = ThumbnailReference(
                blobID: BlobID(uuid: thumbnailBlob), pixelWidth: thumbnailWidth, pixelHeight: thumbnailHeight,
                byteSize: thumbnailBytes)
        default:
            return nil
        }
        return ImageReference(
            blobID: BlobID(uuid: blob), typeIdentifier: type, pixelWidth: width, pixelHeight: height,
            byteSize: byteSize, contentHash: ContentHash(bytes: [UInt8](hash)), thumbnail: thumbnail)
    }

    private static func decodeFiles(_ reader: inout Reader) -> [FileReference]? {
        guard let count = reader.integer(), count > 0 else {
            return nil
        }
        var files: [FileReference] = []
        for _ in 0..<count {
            guard let address = reader.string(), let url = URL(string: address), url.isFileURL,
                let name = reader.string(), let hasSize = reader.byte()
            else {
                return nil
            }
            var byteSize: Int?
            switch hasSize {
            case 0:
                byteSize = nil
            case 1:
                guard let size = reader.integer() else {
                    return nil
                }
                byteSize = size
            default:
                return nil
            }
            let thumbnail: FileThumbnail?
            do {
                thumbnail = try decodeFileThumbnail(&reader)
            } catch {
                return nil
            }
            files.append(FileReference(url: url, name: name, byteSize: byteSize, thumbnail: thumbnail))
        }
        return files
    }

    /// A file's thumbnail: a 0 byte for none, or a 1 byte, the kind, the blob ID, the pixel size and
    /// the byte size. Throws when the data is damaged.
    private static func decodeFileThumbnail(_ reader: inout Reader) throws(DamagedPayload) -> FileThumbnail? {
        switch reader.byte() {
        case 0:
            return nil
        case 1:
            guard let kindByte = reader.byte(), let kind = FileThumbnail.Kind(rawValue: kindByte),
                let blob = reader.uuid(), let width = reader.integer(), let height = reader.integer(),
                let byteSize = reader.integer()
            else {
                throw DamagedPayload()
            }
            let reference = ThumbnailReference(
                blobID: BlobID(uuid: blob), pixelWidth: width, pixelHeight: height, byteSize: byteSize)
            return FileThumbnail(kind: kind, reference: reference)
        default:
            throw DamagedPayload()
        }
    }

    /// A payload that does not have the layout its format byte says.
    private struct DamagedPayload: Error {}

    private struct Writer {
        private(set) var data = Data()

        mutating func byte(_ value: UInt8) {
            data.append(value)
        }

        mutating func raw(_ value: Data) {
            data.append(value)
        }

        /// A non-negative integer as 8 bytes.
        mutating func integer(_ value: Int) {
            let unsigned = UInt64(max(value, 0))
            let shifts = stride(from: 56, through: 0, by: -8)
            data.append(contentsOf: shifts.map { UInt8(truncatingIfNeeded: unsigned >> UInt64($0)) })
        }

        mutating func bytes(_ value: Data) {
            data.appendLengthPrefixed(value)
        }

        mutating func string(_ value: String) {
            bytes(Data(value.utf8))
        }

        mutating func uuid(_ value: UUID) {
            withUnsafeBytes(of: value.uuid) { data.append(contentsOf: $0) }
        }

        mutating func fileThumbnail(_ thumbnail: FileThumbnail?) {
            guard let thumbnail else {
                byte(0)
                return
            }
            byte(1)
            byte(thumbnail.kind.rawValue)
            uuid(thumbnail.blobID.uuid)
            integer(thumbnail.reference.pixelWidth)
            integer(thumbnail.reference.pixelHeight)
            integer(thumbnail.reference.byteSize)
        }
    }

    private struct Reader {
        private let input: [UInt8]
        private var offset = 0

        init(_ data: Data) {
            input = [UInt8](data)
        }

        var isAtEnd: Bool {
            offset == input.count
        }

        mutating func byte() -> UInt8? {
            take(1)?.first
        }

        /// Everything not read yet.
        mutating func rest() -> Data {
            Data(take(input.count - offset) ?? [])
        }

        mutating func integer() -> Int? {
            guard let part = take(8) else {
                return nil
            }
            let value = part.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            return value <= UInt64(Int.max) ? Int(value) : nil
        }

        mutating func bytes() -> Data? {
            guard let lengthBytes = take(4) else {
                return nil
            }
            let length = lengthBytes.reduce(0) { ($0 << 8) | Int($1) }
            return take(length).map { Data($0) }
        }

        mutating func string() -> String? {
            bytes().flatMap { String(data: $0, encoding: .utf8) }
        }

        mutating func uuid() -> UUID? {
            guard let part = take(16) else {
                return nil
            }
            return UUID(
                uuid: (
                    part[0], part[1], part[2], part[3], part[4], part[5], part[6], part[7], part[8], part[9],
                    part[10], part[11], part[12], part[13], part[14], part[15]
                ))
        }

        private mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, count <= input.count - offset else {
                return nil
            }
            defer { offset += count }
            return Array(input[offset..<(offset + count)])
        }
    }
}
