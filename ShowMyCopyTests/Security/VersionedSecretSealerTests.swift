import Foundation
import Testing

@testable import ShowMyCopy

struct VersionedSecretSealerTests {
    private let sealer = VersionedSecretSealer(cipher: FakeCipher(key: 0x5A))
    private let secret = Data("correct horse battery staple".utf8)

    @Test func sealedDataStartsWithTheFormatVersion() throws {
        let sealed = try sealer.seal(secret)
        #expect(sealed.first == VersionedSecretSealer<FakeCipher>.formatVersion)
        #expect(VersionedSecretSealer<FakeCipher>.formatVersion == 1)
    }

    @Test func roundTrip() throws {
        let sealed = try sealer.seal(secret)
        #expect(sealed != secret)
        #expect(try sealer.open(sealed) == secret)
    }

    @Test func emptyPlaintextRoundTrip() throws {
        let sealed = try sealer.seal(Data())
        #expect(sealed.count > 1)
        #expect(try sealer.open(sealed) == Data())
    }

    @Test func opensDataThatIsASliceOfALargerBuffer() throws {
        let buffer = Data([0xAA, 0xBB, 0xCC]) + (try sealer.seal(secret))
        let slice = buffer.dropFirst(3)
        #expect(slice.startIndex == 3)
        #expect(try sealer.open(slice) == secret)
    }

    @Test(arguments: [UInt8(0), 2, 0xFF])
    func unknownFormatVersionIsRejected(version: UInt8) throws {
        var sealed = try sealer.seal(secret)
        sealed[sealed.startIndex] = version
        #expect(throws: SecretSealingError.unsupportedFormatVersion(version)) {
            try sealer.open(sealed)
        }
    }

    @Test func emptySealedDataIsRejected() {
        #expect(throws: SecretSealingError.missingFormatVersion) {
            try sealer.open(Data())
        }
    }

    @Test func tamperedCiphertextFailsAuthentication() throws {
        let sealed = try sealer.seal(secret)
        for index in sealed.indices.dropFirst() {
            var tampered = sealed
            tampered[index] ^= 0x01
            #expect(throws: SecretSealingError.authenticationFailed) {
                try sealer.open(tampered)
            }
        }
    }

    @Test func truncatedDataFailsAuthentication() throws {
        let sealed = try sealer.seal(secret)
        #expect(throws: SecretSealingError.authenticationFailed) {
            try sealer.open(sealed.dropLast())
        }
        #expect(throws: SecretSealingError.authenticationFailed) {
            try sealer.open(sealed.prefix(1))
        }
    }

    @Test func dataSealedWithAnotherKeyFailsAuthentication() throws {
        let other = VersionedSecretSealer(cipher: FakeCipher(key: 0x33))
        let sealed = try other.seal(secret)
        #expect(throws: SecretSealingError.authenticationFailed) {
            try sealer.open(sealed)
        }
    }

    @Test func formatVersionIsAuthenticatedByTheCipher() throws {
        // The header is passed to the cipher as authenticated data, so a future version cannot open data sealed
        // under another version by mistake: the cipher sees a different header.
        let sealed = try sealer.seal(secret)
        let cipher = FakeCipher(key: 0x5A)
        let body = Data(sealed.dropFirst())
        #expect(try cipher.open(body, authenticating: Data([1])) == secret)
        #expect(throws: FakeCipherError.self) {
            try cipher.open(body, authenticating: Data([2]))
        }
    }
}
