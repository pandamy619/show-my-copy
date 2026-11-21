import Foundation
import Testing

@testable import ShowMyCopy

struct ProtobufReaderTests {
    @Test func readsEveryWireType() throws {
        var reader = ProtobufReader(
            ProtobufWriter().varint(1, 150).bytes(2, Data("hi".utf8)).fixed64(3, 0x0102_0304_0506_0708)
                .fixed32(4, 0xDEAD_BEEF).varint(5, UInt64.max).data)
        #expect(try reader.next() == .init(number: 1, value: .varint(150)))
        #expect(try reader.next() == .init(number: 2, value: .bytes(Data("hi".utf8))))
        #expect(try reader.next() == .init(number: 3, value: .fixed64(0x0102_0304_0506_0708)))
        #expect(try reader.next() == .init(number: 4, value: .fixed32(0xDEAD_BEEF)))
        #expect(try reader.next() == .init(number: 5, value: .varint(UInt64.max)))
        #expect(try reader.next() == nil)
        #expect(try reader.next() == nil)
    }

    @Test func anEmptyMessageHasNoFields() throws {
        var reader = ProtobufReader(Data())
        #expect(try reader.next() == nil)
    }

    @Test(arguments: [
        Data([0x08]),  // tag, no value
        Data([0x12, 0x05, 0x01]),  // 5 bytes promised, 1 given
        Data([0x19, 0x01, 0x02]),  // fixed64 cut short
        Data([0x25, 0x01]),  // fixed32 cut short
        Data([0x80]),  // varint cut short
    ])
    func rejectsTruncatedMessages(bytes: Data) {
        var reader = ProtobufReader(bytes)
        #expect(throws: ProtobufReader.DecodingError.truncated) {
            try reader.next()
        }
    }

    @Test func rejectsVarintsLongerThanTenBytes() {
        var reader = ProtobufReader(Data([0x08] + [UInt8](repeating: 0xFF, count: 11)))
        #expect(throws: ProtobufReader.DecodingError.malformedVarint) {
            try reader.next()
        }
    }

    @Test(arguments: [UInt8(3), 4, 6, 7])
    func rejectsWireTypesItDoesNotKnow(wireType: UInt8) {
        var reader = ProtobufReader(Data([wireType | 1 << 3, 0x00]))
        #expect(throws: ProtobufReader.DecodingError.unsupportedWireType(wireType)) {
            try reader.next()
        }
    }

    @Test func fieldNumbersCanBeLarge() throws {
        var reader = ProtobufReader(ProtobufWriter().varint(536_870_911, 1).data)
        #expect(try reader.next() == .init(number: 536_870_911, value: .varint(1)))
    }
}
