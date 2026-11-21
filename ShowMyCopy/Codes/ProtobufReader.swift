import Foundation

/// Reads the fields of one protocol buffers message, in order, with no schema: enough to decode what Google
/// Authenticator exports without a dependency. Nested messages are returned as bytes for another reader.
struct ProtobufReader {
    enum DecodingError: Error, Equatable, Sendable {
        /// The bytes end in the middle of a field.
        case truncated
        /// A varint longer than 10 bytes.
        case malformedVarint
        /// Wire type 3, 4 (groups, long removed from the format) or 6, 7 (never defined).
        case unsupportedWireType(UInt8)
    }

    enum Value: Equatable, Sendable {
        case varint(UInt64)
        case fixed32(UInt32)
        case fixed64(UInt64)
        case bytes(Data)
    }

    struct Field: Equatable, Sendable {
        let number: Int
        let value: Value
    }

    private var bytes: Data.SubSequence

    init(_ bytes: Data) {
        self.bytes = bytes[...]
    }

    /// The next field, or nil at the end.
    mutating func next() throws(DecodingError) -> Field? {
        guard !bytes.isEmpty else { return nil }
        let tag = try varint()
        let number = Int(tag >> 3)
        let wireType = UInt8(tag & 0x07)
        switch wireType {
        case 0:
            return Field(number: number, value: .varint(try varint()))
        case 1:
            return Field(number: number, value: .fixed64(try fixed(8)))
        case 2:
            let count = try varint()
            guard count <= UInt64(bytes.count) else { throw .truncated }
            let payload = Data(bytes.prefix(Int(count)))
            bytes = bytes.dropFirst(Int(count))
            return Field(number: number, value: .bytes(payload))
        case 5:
            return Field(number: number, value: .fixed32(UInt32(truncatingIfNeeded: try fixed(4))))
        default:
            throw .unsupportedWireType(wireType)
        }
    }

    private mutating func varint() throws(DecodingError) -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<10 {
            guard let byte = bytes.first else { throw .truncated }
            bytes = bytes.dropFirst()
            if index == 9, byte > 0x01 { throw .malformedVarint }
            result |= UInt64(byte & 0x7F) << UInt64(index * 7)
            if byte & 0x80 == 0 { return result }
        }
        throw .malformedVarint
    }

    /// `count` little-endian bytes as one number; `count` is 4 or 8.
    private mutating func fixed(_ count: Int) throws(DecodingError) -> UInt64 {
        guard bytes.count >= count else { throw .truncated }
        var result: UInt64 = 0
        for (index, byte) in bytes.prefix(count).enumerated() {
            result |= UInt64(byte) << UInt64(index * 8)
        }
        bytes = bytes.dropFirst(count)
        return result
    }
}
