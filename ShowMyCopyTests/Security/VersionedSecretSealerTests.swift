import Foundation
import Testing

@testable import ShowMyCopy

struct VersionedSecretSealerTests {
    private typealias Sealer = VersionedSecretSealer<FakeCipher>

    private let cipher = FakeCipher(key: 0x5A)
    private var sealer: Sealer { VersionedSecretSealer(cipher: cipher) }
    private let secret = Data("correct horse battery staple".utf8)
    private let context = SealingContext.historyEntry(UUID())

    /// Data as 0.1.0 and 0.2.0 sealed it: version 1, with the version byte alone authenticated.
    private func sealedByVersion1(_ plaintext: Data) throws -> Data {
        Data([1]) + (try cipher.seal(plaintext, authenticating: Data([1])))
    }

    @Test func sealedDataStartsWithTheFormatVersion() throws {
        let sealed = try sealer.seal(secret, boundTo: context)
        #expect(sealed.first == Sealer.formatVersion)
        #expect(Sealer.formatVersion == 2)
        #expect(Sealer.firstFormatVersion == 1)
    }

    @Test func roundTrip() throws {
        let sealed = try sealer.seal(secret, boundTo: context)
        #expect(sealed != secret)
        #expect(try sealer.open(sealed, boundTo: context) == secret)
    }

    @Test func emptyPlaintextRoundTrip() throws {
        let sealed = try sealer.seal(Data(), boundTo: context)
        #expect(sealed.count > 1)
        #expect(try sealer.open(sealed, boundTo: context) == Data())
    }

    @Test func opensDataThatIsASliceOfALargerBuffer() throws {
        let buffer = Data([0xAA, 0xBB, 0xCC]) + (try sealer.seal(secret, boundTo: context))
        let slice = buffer.dropFirst(3)
        #expect(slice.startIndex == 3)
        #expect(try sealer.open(slice, boundTo: context) == secret)
    }

    @Test func dataBoundToAnotherContextFailsAuthentication() throws {
        // A password copied into another record, or into the accounts file, does not open there.
        let sealed = try sealer.seal(secret, boundTo: context)
        for other in [SealingContext.historyEntry(UUID()), .codeAccounts] {
            #expect(throws: SecretSealingError.authenticationFailed) {
                try sealer.open(sealed, boundTo: other)
            }
        }
        #expect(throws: SecretSealingError.authenticationFailed) {
            try sealer.open(try sealer.seal(secret, boundTo: .codeAccounts), boundTo: context)
        }
    }

    @Test func theContextIsNotStoredWithTheData() throws {
        let sealed = try sealer.seal(secret, boundTo: context)
        #expect(sealed.range(of: context.bytes) == nil)
        #expect(sealed.count == (try sealer.seal(secret, boundTo: .codeAccounts)).count)
    }

    @Test func dataSealedByVersion1OpensWithAnyContext() throws {
        // Saved by 0.1.0 or 0.2.0, before the context was authenticated: still read, until it expires or is written
        // again in the current version.
        let sealed = try sealedByVersion1(secret)
        #expect(try sealer.open(sealed, boundTo: context) == secret)
        #expect(try sealer.open(sealed, boundTo: .codeAccounts) == secret)
    }

    @Test func version1DataThatWasChangedStillFailsAuthentication() throws {
        var sealed = try sealedByVersion1(secret)
        sealed[sealed.count - 1] ^= 0x01
        #expect(throws: SecretSealingError.authenticationFailed) {
            try sealer.open(sealed, boundTo: context)
        }
        // Version 2 data relabelled as version 1 does not open either: the cipher authenticated another header.
        var relabelled = try sealer.seal(secret, boundTo: context)
        relabelled[relabelled.startIndex] = 1
        #expect(throws: SecretSealingError.authenticationFailed) {
            try sealer.open(relabelled, boundTo: context)
        }
    }

    @Test(arguments: [UInt8(3), 0xFF])
    func aNewerFormatVersionIsReportedAsSuch(version: UInt8) throws {
        // The caller leaves such data alone for the newer version that wrote it.
        var sealed = try sealer.seal(secret, boundTo: context)
        sealed[sealed.startIndex] = version
        #expect(throws: SecretSealingError.newerFormatVersion(version)) {
            try sealer.open(sealed, boundTo: context)
        }
        #expect(!SecretSealingError.newerFormatVersion(version).isAboutTheKey)
    }

    @Test func aFormatVersionNoVersionWroteIsRejected() throws {
        var sealed = try sealer.seal(secret, boundTo: context)
        sealed[sealed.startIndex] = 0
        #expect(throws: SecretSealingError.unsupportedFormatVersion(0)) {
            try sealer.open(sealed, boundTo: context)
        }
    }

    @Test func emptySealedDataIsRejected() {
        #expect(throws: SecretSealingError.missingFormatVersion) {
            try sealer.open(Data(), boundTo: context)
        }
    }

    @Test func tamperedCiphertextFailsAuthentication() throws {
        let sealed = try sealer.seal(secret, boundTo: context)
        for index in sealed.indices.dropFirst() {
            var tampered = sealed
            tampered[index] ^= 0x01
            #expect(throws: SecretSealingError.authenticationFailed) {
                try sealer.open(tampered, boundTo: context)
            }
        }
    }

    @Test func truncatedDataFailsAuthentication() throws {
        let sealed = try sealer.seal(secret, boundTo: context)
        #expect(throws: SecretSealingError.authenticationFailed) {
            try sealer.open(sealed.dropLast(), boundTo: context)
        }
        #expect(throws: SecretSealingError.authenticationFailed) {
            try sealer.open(sealed.prefix(1), boundTo: context)
        }
    }

    @Test func dataSealedWithAnotherKeyFailsAuthentication() throws {
        let other = VersionedSecretSealer(cipher: FakeCipher(key: 0x33))
        let sealed = try other.seal(secret, boundTo: context)
        #expect(throws: SecretSealingError.authenticationFailed) {
            try sealer.open(sealed, boundTo: context)
        }
    }

    @Test func formatVersionAndContextAreAuthenticatedByTheCipher() throws {
        // Both are passed to the cipher as authenticated data, so a future version cannot open data sealed under
        // another version by mistake, and no caller can open it for another record: the cipher sees another header.
        let sealed = try sealer.seal(secret, boundTo: context)
        let body = Data(sealed.dropFirst())
        #expect(try cipher.open(body, authenticating: Data([2]) + context.bytes) == secret)
        for header in [Data([2]), Data([1]) + context.bytes, Data([3]) + context.bytes] {
            #expect(throws: FakeCipherError.self) {
                try cipher.open(body, authenticating: header)
            }
        }
    }
}

struct SealingContextTests {
    @Test func recordsAndTheAccountsFileNeverShareAContext() {
        let id = UUID()
        #expect(SealingContext.historyEntry(id) == .historyEntry(id))
        #expect(SealingContext.historyEntry(id) != .historyEntry(UUID()))
        #expect(SealingContext.historyEntry(id) != .codeAccounts)
        #expect(SealingContext.historyEntry(id).bytes.count == "history-entry".utf8.count + 1 + 16)
    }
}
