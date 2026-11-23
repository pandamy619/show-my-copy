import Foundation

@testable import ShowMyCopy

struct FakeSealingError: Error {}

/// Stands in for the Keychain-backed sealer. Not encryption: it puts the key first, then four bytes that stand for
/// the context, then every byte flipped with `key`, so a test can see that the stored bytes are not the plaintext,
/// opening data sealed with another key fails like a lost or replaced key does, and data bound to another record or
/// file fails to open as it does with the real sealer.
struct FakeSecretSealer: SecretSealing {
    var key: UInt8 = 0x5A
    /// Makes `seal` throw, like a Keychain that cannot be reached.
    var failsToSeal = false

    func seal(_ plaintext: Data, boundTo context: SealingContext) throws -> Data {
        guard !failsToSeal else {
            throw FakeSealingError()
        }
        return Data([key]) + Self.tag(of: context) + Data(plaintext.map { $0 ^ key })
    }

    func open(_ sealed: Data, boundTo context: SealingContext) throws -> Data {
        let bytes = Data(sealed)
        guard bytes.first == key, bytes.count >= 5, bytes[1..<5] == Self.tag(of: context) else {
            throw FakeSealingError()
        }
        return Data(bytes.dropFirst(5).map { $0 ^ key })
    }

    private static func tag(of context: SealingContext) -> Data {
        var value: UInt32 = 2_166_136_261
        for byte in context.bytes {
            value = (value ^ UInt32(byte)) &* 16_777_619
        }
        return withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
