import Foundation

/// Builds protocol buffers messages for tests, one field at a time.
struct ProtobufWriter {
    private(set) var data = Data()

    func varint(_ number: Int, _ value: UInt64) -> ProtobufWriter {
        appending(tag(number, wireType: 0) + Self.varint(value))
    }

    func bytes(_ number: Int, _ value: Data) -> ProtobufWriter {
        appending(tag(number, wireType: 2) + Self.varint(UInt64(value.count)) + value)
    }

    func string(_ number: Int, _ value: String) -> ProtobufWriter {
        bytes(number, Data(value.utf8))
    }

    func message(_ number: Int, _ value: ProtobufWriter) -> ProtobufWriter {
        bytes(number, value.data)
    }

    func fixed64(_ number: Int, _ value: UInt64) -> ProtobufWriter {
        appending(tag(number, wireType: 1) + withUnsafeBytes(of: value.littleEndian) { Data($0) })
    }

    func fixed32(_ number: Int, _ value: UInt32) -> ProtobufWriter {
        appending(tag(number, wireType: 5) + withUnsafeBytes(of: value.littleEndian) { Data($0) })
    }

    private func tag(_ number: Int, wireType: UInt64) -> Data {
        Self.varint(UInt64(number) << 3 | wireType)
    }

    private func appending(_ bytes: Data) -> ProtobufWriter {
        var copy = self
        copy.data.append(bytes)
        return copy
    }

    private static func varint(_ value: UInt64) -> Data {
        var rest = value
        var out = Data()
        repeat {
            let byte = UInt8(rest & 0x7F)
            rest >>= 7
            out.append(rest == 0 ? byte : byte | 0x80)
        } while rest != 0
        return out
    }
}
