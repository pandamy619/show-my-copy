import Foundation

@testable import ShowMyCopy

enum FakeCipherError: Error {
    case authenticationFailure
}

/// Stands in for AES-GCM in tests that run where CryptoKit is missing. It is NOT encryption: it only flips bits with
/// the key and appends a checksum over key, authenticated data and plaintext, so tests can check the framing around
/// the cipher, including that a changed byte, another key or other authenticated data makes `open` fail.
struct FakeCipher: AuthenticatedCipher {
    let key: UInt8

    func seal(_ plaintext: Data, authenticating header: Data) throws -> Data {
        let body = Data(plaintext.map { $0 ^ key })
        return body + checksum(header: header, plaintext: plaintext)
    }

    func open(_ box: Data, authenticating header: Data) throws -> Data {
        guard box.count >= 4 else { throw FakeCipherError.authenticationFailure }
        let plaintext = Data(box.dropLast(4).map { $0 ^ key })
        guard Data(box.suffix(4)) == checksum(header: header, plaintext: plaintext) else {
            throw FakeCipherError.authenticationFailure
        }
        return plaintext
    }

    private func checksum(header: Data, plaintext: Data) -> Data {
        var value: UInt32 = 2_166_136_261
        for byte in [key] + Array(header) + [0xFF] + Array(plaintext) {
            value = (value ^ UInt32(byte)) &* 16_777_619
        }
        return withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
