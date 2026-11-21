import Foundation
import Testing

@testable import ShowMyCopy

/// The accounts file on a real disk, sealed with a fake cipher.
struct SealedCodeAccountsFileTests {
    private let directory: URL
    private let sealer = VersionedSecretSealer(cipher: FakeCipher(key: 0x5A))

    init() {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "SealedCodeAccountsFileTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func makeFile(sealer: (any SecretSealing)? = nil) -> SealedCodeAccountsFile {
        SealedCodeAccountsFile(directory: directory, sealer: sealer ?? self.sealer)
    }

    private func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func noFileMeansNoAccounts() async {
        defer { removeDirectory() }
        #expect(await makeFile().load() == .accounts([]))
    }

    @Test func savesAndLoadsTheAccountsSealed() async throws {
        defer { removeDirectory() }
        let file = makeFile()
        let accounts = [
            CodeFixtures.stored(), CodeFixtures.stored(issuer: "Google", secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"),
        ]

        try await file.save(accounts)

        #expect(await file.load() == .accounts(accounts))
        let onDisk = try #require(FileManager.default.contents(atPath: file.fileURL.path(percentEncoded: false)))
        // Sealed: neither the names nor the secrets are on disk as they are.
        #expect(onDisk.range(of: Data("GitHub".utf8)) == nil)
        #expect(onDisk.range(of: Data("JBSWY3DPEHPK3PXP".utf8)) == nil)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func savingAnEmptyListDeletesTheFile() async throws {
        defer { removeDirectory() }
        let file = makeFile()
        try await file.save([CodeFixtures.stored()])

        try await file.save([])

        #expect(!FileManager.default.fileExists(atPath: file.fileURL.path(percentEncoded: false)))
        #expect(await file.load() == .accounts([]))
    }

    @Test func aChangedFileIsDamagedAndLeftAlone() async throws {
        defer { removeDirectory() }
        let file = makeFile()
        try await file.save([CodeFixtures.stored()])
        var bytes = try #require(FileManager.default.contents(atPath: file.fileURL.path(percentEncoded: false)))
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: file.fileURL)

        #expect(await file.load() == .damaged)
        #expect(FileManager.default.contents(atPath: file.fileURL.path(percentEncoded: false)) == bytes)
    }

    @Test func aFileSealedWithAnotherKeyIsDamaged() async throws {
        defer { removeDirectory() }
        try await makeFile().save([CodeFixtures.stored()])

        let other = makeFile(sealer: VersionedSecretSealer(cipher: FakeCipher(key: 0x33)))
        #expect(await other.load() == .damaged)
    }

    @Test func aKeyThatIsNotReadyStopsLoadingAndSaving() async throws {
        defer { removeDirectory() }
        let saved = CodeFixtures.stored()
        try await makeFile().save([saved])

        let lockedOut = makeFile(sealer: UnreadySealer(state: .lockedOut))
        #expect(await lockedOut.load() == .keyLockedOut)
        let unavailable = makeFile(sealer: UnreadySealer(state: .unavailable))
        #expect(await unavailable.load() == .keyUnavailable)
        await #expect(throws: CodeAccountsSaveError.keyNotReady) {
            try await lockedOut.save([CodeFixtures.stored(issuer: "New")])
        }
        // The file is as it was.
        #expect(await makeFile().load() == .accounts([saved]))
    }

    @Test func decodesTheFormatAndRejectsWhatItCannotMakeAccountsOf() throws {
        let accounts = [CodeFixtures.stored()]
        let json = try SealedCodeAccountsFile.encode(accounts)
        #expect(SealedCodeAccountsFile.decode(json) == .accounts(accounts))

        var object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        object["version"] = SealedCodeAccountsFile.formatVersion + 1
        #expect(SealedCodeAccountsFile.decode(try JSONSerialization.data(withJSONObject: object)) == .newerFormat)

        object["version"] = SealedCodeAccountsFile.formatVersion
        var records = try #require(object["accounts"] as? [[String: Any]])
        records[0]["algorithm"] = "MD5"
        object["accounts"] = records
        #expect(SealedCodeAccountsFile.decode(try JSONSerialization.data(withJSONObject: object)) == .damaged)
        records[0]["algorithm"] = "SHA1"
        records[0]["period"] = OneTimeCodeAccount.periodRange.upperBound + 1
        object["accounts"] = records
        #expect(SealedCodeAccountsFile.decode(try JSONSerialization.data(withJSONObject: object)) == .damaged)
        #expect(SealedCodeAccountsFile.decode(Data("not json".utf8)) == .damaged)
    }
}

/// A sealer whose key never gets ready.
private struct UnreadySealer: SecretSealing {
    let state: SealingKeyState

    func seal(_ plaintext: Data) throws -> Data {
        throw SecretSealingError.keyNotLoaded
    }

    func open(_ sealed: Data) throws -> Data {
        throw SecretSealingError.keyNotLoaded
    }

    func loadKey() async -> SealingKeyState {
        state
    }
}
